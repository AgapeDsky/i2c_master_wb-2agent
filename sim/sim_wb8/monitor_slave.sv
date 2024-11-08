`ifndef MONITOR_SLAVE
`define MONITOR_SLAVE

// `include "sequence_slave.svh"
// `include "config.svh"

class i2c_slave_monitor extends uvm_monitor;

    /*************************
    * Component Initialization
    **************************/
    // register object to UVM Factory
    `uvm_component_utils(i2c_slave_monitor);

    // constructor
    function new (string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // analysis port
    uvm_analysis_port #(sequence_item_base) monitor_slave_ap;

    // set monitor-DUT interface
    virtual i2c_interface vif;
    sequence_item_slave i2c_tlm_obj;
    wb8_i2c_test_config config_obj;
    function void build_phase (uvm_phase phase);
        if (!uvm_config_db #(wb8_i2c_test_config)::get(this, "", "wb8_i2c_test_config", config_obj)) begin
            `uvm_error("", "uvm_config_db::monitor_slave.svh get failed on BUILD_PHASE")
        end
        vif = config_obj.i2c_vif.monitor;
        monitor_slave_ap = new("monitor_slave_ap", this);
    endfunction

    /*************************
    * Internal Properties
    **************************/
    // State Enumeration
    typedef enum {  RESP_IDLE, 
                    RESP_REGADDR_WAIT, 
                    RESP_RW_WAIT, 
                    RESP_READ, 
                    RESP_WRITE
                    } resp_state_type;  // Slave Driver FSM
    typedef enum {  PACKET_ACK,
                    PACKET_NACK
                    } packet_type;      // Received Packet ACK type
    typedef enum {  CMD_NONE,
                    CMD_START,
                    CMD_STOP
                    } command_type;     // Start/Stop Bit type

    // Variables
    resp_state_type resp_state = RESP_IDLE;
    command_type command;
    packet_type packet;
    bit start, stop, ack;
    bit [7:0] data;
    bit flip;
    integer i;

    // TLM packet
    sequence_item_slave req;
    sequence_item_slave rsp;
    bit [7:0] reg_addr;
    bit [7:0] reg_data;
    bit       reg_rw;

    // Methods
    task communicate_to_scoreboard;

        // send data to the scoreboard and coverage collector when the transaction completes
        i2c_tlm_obj = sequence_item_slave::type_id::create("i2c_observer");
        i2c_tlm_obj.data = reg_data;
        i2c_tlm_obj.addr = reg_addr;
        i2c_tlm_obj.rw = reg_rw;
        monitor_slave_ap.write(i2c_tlm_obj);

    endtask

    task get_next_state;
        // A function to decode the next responder (slave) state based on the current state and the input
        if ((command == CMD_STOP)) begin
            resp_state = RESP_IDLE;
        end

        else begin // packet acknowledged
            // idle state
            if (resp_state == RESP_IDLE) begin
                if (command == CMD_START) begin
                    if (data == (8'h6<<1)) begin
                        resp_state = RESP_REGADDR_WAIT;
                         `uvm_info("MONITOR_SLAVE::STATE_FSM", "Device is being accessed: dev_addr 0x6", UVM_MEDIUM)
                    end
                end
            end

            // state after device address input, waiting for register address
            else if (resp_state == RESP_REGADDR_WAIT) begin
                if (command == CMD_NONE) begin
                    resp_state = RESP_RW_WAIT;
                    `uvm_info("MONITOR_SLAVE::STATE_FSM", $sformatf("Internal address is being accessed: reg_addr 0x%2h", data), UVM_MEDIUM)
                    reg_addr = data;
                end
            end

            // state after register address input, waiting for next cmd (R/W)
            else if (resp_state == RESP_RW_WAIT) begin
                // if we get a start command, then the operation is READ
                if (command == CMD_START) begin
                    resp_state = RESP_READ;
                    `uvm_info("MONITOR_SLAVE::STATE_FSM", "Device is being read: dev_addr 0x6", UVM_MEDIUM)
                    reg_rw = 0;
                end
                else if (command == CMD_NONE) begin
                    // if we get a packet without a specific command (CMD_NONE), then the operation is WRITE
                    resp_state = RESP_WRITE;
                    `uvm_info("MONITOR_SLAVE::STATE_FSM", $sformatf("Writing: data 0x%2h", data), UVM_MEDIUM)
                    reg_rw = 1;
                    reg_data = data;
                    // post data to scoreboard
                    communicate_to_scoreboard;
                end
            end

            // read state latch
            else if (resp_state == RESP_READ) begin
                reg_data = data;
                reg_rw = 0;

                if (packet == PACKET_ACK) begin
                    // if packet is still acknowledged, then the data is still being read in an incremental address
                    reg_addr = reg_addr + 1;
                    communicate_to_scoreboard;
                    `uvm_info("MONITOR_SLAVE::STATE_FSM", $sformatf("Reading: data 0x%2h", reg_data), UVM_MEDIUM)
                end
                else begin
                    // if the packet is NACK, then the read operation is done
                    communicate_to_scoreboard;
                    `uvm_info("MONITOR_SLAVE::STATE_FSM", $sformatf("Reading: data 0x%2h", reg_data), UVM_MEDIUM)
                    resp_state = RESP_IDLE;
                end

            end

            // write state latch
            else if (resp_state == RESP_WRITE) begin
                `uvm_info("MONITOR_SLAVE::STATE_FSM", $sformatf("Writing: data 0x%2h", data), UVM_MEDIUM)
                reg_addr = reg_addr + 1;
                reg_rw = 1;
                reg_data = data;
                // post data to the scoreboard
                communicate_to_scoreboard;
            end
        end
    endtask

    // pin-level processing tasks
    task read_packet;
        begin
            start = 0;                             // start bit variable
            stop = 0;                              // stop bit variable
            ack = 0;                               // ack/nack variable
            data = 0;                              // data packet (8 bits)
			
            fork
                // THREAD 1 :: check for start bit
                begin
                    forever begin
                        @(negedge vif.sda_i);
                        if (vif.scl_i == 1'b1) begin
                            start = 1;
                        end
                    end
                end

                begin
                    // THREAD 2 :: check for stop bit
                    forever begin
                        @(posedge vif.sda_i);
                        if (vif.scl_i == 1'b1) begin
                            stop = 1;
                            break;
                        end
                    end
                end

                // THREAD 3 :: retrieve data
                begin
                    for(i=0; i<8+(start && resp_state!=RESP_IDLE); i=i+1) begin
                        @(posedge vif.scl_i);
                        data = (data << 1) | vif.sda_i;
                    end
                    // set ack bit
                    @(negedge vif.scl_i);
                    #5;
                    // read ack bit
                    @(posedge vif.scl_i);
                    #5;
                    ack = ~vif.sda_i;
                    // wait until transfer finish
                    @(negedge vif.scl_i);
                    // making sure no race condition is happening
                    #5;
                end

            join_any
            disable fork;
            
        end
    endtask


    // define driver behavior
    task run_phase (uvm_phase phase);

        forever begin
            // read packet
            read_packet;

            // encode command
            if (stop) command = CMD_STOP;
            else if (start) command = CMD_START;
            else command = CMD_NONE;
            // encode packet
            if (ack) packet = PACKET_ACK;
            else packet = PACKET_NACK;

            // compute next state
            get_next_state;

        end

    endtask

endclass

`endif