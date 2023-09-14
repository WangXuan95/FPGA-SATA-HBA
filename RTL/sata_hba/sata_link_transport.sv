
//--------------------------------------------------------------------------------------------------------
// Module  : sata_link_transport
// Type    : synthesizable, IP's sub-module
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: SATA host (HBA) link and transport layer controller
//           implement simple FIS transfer and receive
//--------------------------------------------------------------------------------------------------------

`timescale 1ns/1ps

module sata_link_transport #(
    parameter TX_CONT_ENABLE = "FALSE"
) (
    // driving clock and reset
    input  wire        core_rstn,
    input  wire        clk,
    // =1 : link initialized
    output reg         link_initialized,
    // Link<->PHY : control and OOB
    output wire        rx_pcs_rstn,       // GT RX PCS reset_n
    input  wire        rx_locked,         // GT PLL is locked
    input  wire        rx_cominit,
    input  wire        rx_comwake,
    input  wire        rx_elecidle,
    input  wire        rx_byteisaligned,  // RX byte alignment completed
    output reg         tx_cominit,
    output reg         tx_comwake,
    output reg         tx_elecidle,
    // PHY->Link : RX data (clock domain = clk)
    input  wire        rx_charisk,        // RX byte is K. rx_charisk=1 : rx_datain[7:0] is K (control value) (e.g., 8'hBC = K28.5)
    input  wire [15:0] rx_datain,         // RX data
    // PHY<-Link : TX data (clock domain = clk)
    output reg         tx_charisk,        // TX byte is K. rx_charisk=1 : rx_datain[7:0] is K (control value) (e.g., 8'hBC = K28.5)
    output reg  [15:0] tx_dataout,        // TX data
    // Transport->Command : RX FIS data stream (AXI-stream liked, without tready handshake, clock domain = clk)
    //   example wave :               // |  no data  |  FIS1 (no error)  |  no data  | FIS2 (error) |   no data   |  FIS3 (no error)  |   no data   |
    output reg         rfis_tvalid,   // 000000000000111111111111111111111000000000000000000000000000000000000000011111111111111111111100000000000000     // rfis_tvalid=1 indicate rfis_tdata is valid. rfis_tvalid is always continuous (no bubble) when output a FIS
    output reg         rfis_tlast,    // 000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000100000000000000     // rfis_tlast=1  indicate this data is the last data of a FIS
    output reg  [31:0] rfis_tdata,    // XXXXXXXXXXXXDDDDDDDDDDDDDDDDDDDDDXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXDDDDDDDDDDDDDDDDDDDDDXXXXXXXXXXXXXX     // data, little endian : [7:0]->byte0, [15:8]->byte1, [23:16]->byte2, [31:24]->byte3
    output reg         rfis_err,      // 000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000     // indicate a error FIS is detected (CRC error or illegal length), the error FIS do not effect rfis_tvalid, rfis_tlast and rfis_tdata
    // Transport<-Command : TX FIS data stream (AXI-stream liked, clock domain = clk)
    //   example wave :               // | idle  | write FIS1 to buffer  |  FIS1 transfer in progress (no error) |  idle  |  write FIS2 to buffer |  FIS2 transfer in progress (error)  |  idle  |
    input  wire        xfis_tvalid,   // 000000001111101001110111101111110000000000000000000000000000000000000000000000000111111111111111111111111000000000000000000000000000000000000000000000000     // xfis_tvalid=1 indicate xfis_tdata is valid, that is, user want to write data to internal TX FIS buffer. xfis_tvalid handshake with xfis_tready (data will write successfully to TX FIS buffer only when xfis_tvalid=xfis_tready=1). xfis_tvalid allows continuous (no bubble) or discontinuous (insert bubbles)
    input  wire        xfis_tlast,    // 000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000     // xfis_tlast=1  indicate this data is the last data of a FIS. this FIS will transfer to SATA device in progress after xfis_tlast=1 (xfis_tready turn to 0)
    input  wire [31:0] xfis_tdata,    // XXXXXXXXDDDDDXDXXDDDXDDDDXDDDDDDXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXDDDDDDDDDDDDDDDDDDDDDDDDXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX     // data, little endian : [7:0]->byte0, [15:8]->byte1, [23:16]->byte2, [31:24]->byte3
    output wire        xfis_tready,   // 111111111111111111111111111111110000000000000000000000000000000000000000111111111111111111111111111111111000000000000000000000000000000000000001111111111     // xfis_tready=1 indicate FIS transfer is idle, user is allowed to write data to internal TX FIS buffer. while xfis_tready=0 indicate FIS transfer in progress, user is NOT allowed to write data to TX FIS buffer. xfis_tvalid handshake with xfis_tready (data will write successfully to TX FIS buffer only when xfis_tvalid=xfis_tready=1). xfis_tready will turn to 1 at the next cycle of xfis_done=1
    output reg         xfis_done,     // 000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000010000000000     // xfis_done=1 when FIS transfer progress ending, xfis_done=1. and xfis_tready will turn to 1 at the next cycle.
    output reg         xfis_err       // 000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000     // when xfis_done=1, xfis_err=1 indicates FIS transfer error (the SATA device feedback R_ERR).
);


/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// constants
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
localparam [15:0] FIS_LEN_MAX               = 16'd2050;           // FIS max length : 8200 bytes = 2050 dwords (including CRC)
localparam        RXFIS_BUF_DEPTH_LEVEL     = 12;                 // RX FIS ring buffer length = (2^RXFIS_BUF_DEPTH_LEVEL), which must larger than 1.5*FIS_LEN_MAX
localparam        INSERT_ALIGN_PERIOD_LEVEL = 7;                  // TX will insert 2 ALIGN primitives every (2^INSERT_ALIGN_PERIOD_LEVEL) DWORDS. Here we insert 2 ALIGNs every 128 DWORDS, while SATA specification requires to insert at least 2 ALIGNs every 256 DWORDS.
localparam [ 2:0] REPLACE_PRIM_WITH_CONT_ON_REPEAT_COUNT = 3'd4;  // when a repeatable primitive repeat for 4 times, replace the next same primitive with CONT 
localparam [15:0] SCRAMBLER_INIT_VALUE      = 16'hCEF8;
localparam [31:0] SCRAMBLER_RES_INIT_VALUE  = 32'hC2D2768D;
localparam [31:0] CRC_INIT_VALUE            = 32'h52325032;
localparam [31:0]   PRIM_ALIGN    = 32'h7B4A4ABC,   // SATA primitives definition
                    PRIM_CONT     = 32'h9999AA7C,
                    PRIM_SYNC     = 32'hB5B5957C,
                    PRIM_R_RDY    = 32'h4A4A957C,
                    PRIM_R_IP     = 32'h5555B57C,
                    PRIM_R_OK     = 32'h3535B57C,
                    PRIM_R_ERR    = 32'h5656B57C,
                    PRIM_X_RDY    = 32'h5757B57C,
                    PRIM_SOF      = 32'h3737B57C,
                    PRIM_EOF      = 32'hD5D5B57C,
                    PRIM_WTRM     = 32'h5858B57C,
                    PRIM_HOLD     = 32'hD5D5AA7C,
                    PRIM_HOLDA    = 32'h9595AA7C,
                    PRIM_DIALTONE = 32'h4A4A4A4A;   // dail-tone is a pseudo-primitive



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// scrambler function
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
function automatic logic [47:0] func_scrambler32(input logic [15:0] scramble_curr);
    logic        x16;
    logic [15:0] scramble_next = scramble_curr;
    logic [31:0] scramble_res = 0;
    for(int i=0; i<32; i++) begin
        x16 = scramble_next[0];
        scramble_next = (scramble_next>>1) ^ {x16, 3'h0, x16, 8'h0, x16, 1'b0, x16};    // compute G(x) = x^16+x^15+x^13+x^4+1
        scramble_res = {x16, scramble_res[31:1]};
    end
    return {scramble_res, scramble_next};
endfunction



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// CRC function
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
function automatic logic [31:0] func_crc32(input logic [31:0] crc_curr, input logic [31:0] datain);
    logic        x32;
    logic [31:0] crc_next = crc_curr;
    logic [31:0] data_shift = datain;
    for(int i=0; i<32; i++) begin
        x32 = crc_next[31] ^ data_shift[31];
        data_shift = (data_shift<<1);
        crc_next = (crc_next<<1) ^ {5'h0, x32, 2'h0, x32, x32, 5'h0, x32, 3'h0, x32, x32, x32, 1'b0, x32, x32, 1'b0, x32, x32, 1'b0, x32, x32, x32};
    end
    return crc_next;
endfunction



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// judge a primitive is a repeatable primitive or not
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
function automatic logic is_repeatable(input logic [31:0] data);
    return ( data == PRIM_SYNC || data == PRIM_R_RDY || data == PRIM_R_IP || data == PRIM_R_OK || data == PRIM_R_ERR || data == PRIM_X_RDY || data == PRIM_WTRM || data == PRIM_HOLD || data == PRIM_HOLDA );
endfunction



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// output reg initialize
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
initial link_initialized = 1'b0;
initial {tx_cominit, tx_comwake, tx_elecidle} = '0;
initial {rfis_tvalid, rfis_tlast, rfis_tdata, rfis_err} = '0;
initial {xfis_done, xfis_err} <= '0;



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// variables
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
reg         link_rstn = '0;              // link_rstn : in clk domain, is to reset all datapath, but exclude the main FSM

reg         flip = 1'b0;
reg         insert_align = 1'b0;
reg  [INSERT_ALIGN_PERIOD_LEVEL-1:0] insert_align_cnt = '0;

reg         rx_charisk_r0 = '0, rx_charisk_r = '0;
reg  [31:0] rx_datain_r = '0;

reg         rx_dword_flip = 1'b0;
reg         rx_dword_payload = 1'b0;
reg         rx_dword_en = 1'b0;
reg         rx_dword_prim = 1'b0;
reg  [31:0] rx_dword = '0;

reg         rx_pastisprim = 1'b0;
reg         rx_conting = 1'b0;
reg         rx_prim_en = '0;
reg         rx_data_en = '0;
reg  [31:0] rx_data = '0;

reg         dev_is_synced = 1'b0;

reg  [31:0] counter = 0;
reg  [23:0] rx_align_lost_cnt = '0;

enum logic [4:0] {           // main FSM state
    RESET, WAIT_AFTER_RESET, HANDSHAKE_COMINIT, HANDSHAKE_COMWAKE, WAIT_ELECNIDLE, HOST_DIALTONE, WAIT_DEV_SYNC,  // link initialization
    IDLE,                                                                                                         // IDLE
    RECV_RDY, RECV_IP, RECV_OK, RECV_ERR,                                                                         // receive FIS
    SEND_RDY, SEND_SOF, SEND_FIS, SEND_CRC, SEND_EOF, SEND_WTRM, SEND_END_SYNC                                    // send FIS
} state_next ,  state = RESET ;

reg         tx_prim1 = 1'b0;
reg  [31:0] tx_data1 = '0;
reg  [15:0] tx_dataoutr = '0;
reg         tx_chariskr = '0;

reg         rfisb_end = '0;    // RX FIS data stream (before de-scramble and CRC check)
reg         rfisb_en = '0;     // RX FIS data stream (before de-scramble and CRC check)
reg  [31:0] rfisb_data = '0;   // RX FIS data stream (before de-scramble and CRC check)

reg         rfisa_end = '0;    // RX FIS data stream (after de-scramble and CRC check), rfisa_end=1 indicates FIS has end
reg         rfisa_err = '0;    // RX FIS data stream (after de-scramble and CRC check), rfisa_err=1 indicates FIS has CRC error. rfisa_err must be sampled when rfisa_end=1
reg         rfisa_en = '0;     // RX FIS data stream (after de-scramble and CRC check), rfisa_en=1 indicates rfisa_data is enabled
reg  [31:0] rfisa_data = '0;   // RX FIS data stream (after de-scramble and CRC check), rfisa_data must be sampled when rfisa_en=1

reg         rfisc_en = '0;
reg         rfisc_last = '0;
reg         rfisc_err = '0;
reg  [31:0] rfisc_data = '0;

reg  [RXFIS_BUF_DEPTH_LEVEL-1:0] rfisbuf_wbase = '0;
reg  [RXFIS_BUF_DEPTH_LEVEL-1:0] rfisbuf_waddr = '0;
reg  [RXFIS_BUF_DEPTH_LEVEL-1:0] rfisbuf_raddr = '0;
reg  [ 1:0] rfisbuf_lasterr_mem [(1<<RXFIS_BUF_DEPTH_LEVEL)];      // {last, err} , will automatically synthesis to BRAM
reg  [31:0] rfisbuf_data_mem    [(1<<RXFIS_BUF_DEPTH_LEVEL)];      // {     data} , will automatically synthesis to BRAM

reg         xfis_idle = 1'b1;
reg  [15:0] xfisbuf_waddr = '0;
reg  [15:0] xfisbuf_raddr = '0;
reg  [31:0] xfisbuf_rdata;                 // BRAM read-out signal, not a real register

reg  [31:0] xfisbuf_mem [FIS_LEN_MAX];     // will automatically synthesis to BRAM

reg  [15:0] r_scramble     = SCRAMBLER_INIT_VALUE;
reg  [31:0] r_scramble_res = SCRAMBLER_RES_INIT_VALUE;
reg  [31:0] r_crc          = CRC_INIT_VALUE;

reg  [15:0] x_scramble     = SCRAMBLER_INIT_VALUE;
reg  [31:0] x_scramble_res = SCRAMBLER_RES_INIT_VALUE;
reg  [31:0] x_crc          = CRC_INIT_VALUE;



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// free-run counters
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
always@(posedge clk) begin
    flip <= ~flip;
    if(flip) begin
        insert_align <= (insert_align_cnt[INSERT_ALIGN_PERIOD_LEVEL-1:1] == '1);      // insert_align=1 indicates that TX should insert a ALIGN.
        insert_align_cnt <= insert_align_cnt + (INSERT_ALIGN_PERIOD_LEVEL)'(1);
    end
end



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// RX data (from PHY layer) : shift chain
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
always @(posedge clk) begin
    {rx_charisk_r0, rx_charisk_r} <= {rx_charisk, rx_charisk_r0};
    rx_datain_r <= {rx_datain, rx_datain_r[31:16]};
end


/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// RX data (from PHY layer) : convert WORD to DWORD, filter unused primitives and data
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
always @ (posedge clk or negedge link_rstn)
    if(~link_rstn) begin
        rx_dword_flip <= 1'b0;
        rx_dword_payload <= 1'b0;
        rx_dword_en <= 1'b0;
        rx_dword_prim <= 1'b0;
        rx_dword <= '0;
    end else begin
        rx_dword_flip <= (rx_charisk_r && rx_datain_r==PRIM_ALIGN) ? 1'b0 : (~rx_dword_flip);
        if(rx_dword_flip) begin
            rx_dword_en <= 1'b0;
            rx_dword_prim <= rx_charisk_r;
            rx_dword <= rx_datain_r;
            if(rx_charisk_r) begin
                case(rx_datain_r)  // rx_dword_en=0 is to filter unused primitives : we only allow some of the primitives to transfer to next stage
                    PRIM_CONT  : begin  rx_dword_en <= 1'b1;                             end
                    PRIM_SYNC  : begin  rx_dword_en <= 1'b1;  rx_dword_payload <= 1'b0;  end
                    PRIM_R_RDY : begin  rx_dword_en <= 1'b1;                             end
                    PRIM_R_IP  : begin  rx_dword_en <= 1'b1;                             end
                    PRIM_R_OK  : begin  rx_dword_en <= 1'b1;                             end
                    PRIM_R_ERR : begin  rx_dword_en <= 1'b1;                             end
                    PRIM_X_RDY : begin  rx_dword_en <= 1'b1;  rx_dword_payload <= 1'b0;  end
                    PRIM_SOF   : begin  rx_dword_en <= 1'b1;  rx_dword_payload <= 1'b1;  end
                    PRIM_EOF   : begin  rx_dword_en <= 1'b1;  rx_dword_payload <= 1'b0;  end
                    PRIM_WTRM  : begin  rx_dword_en <= 1'b1;  rx_dword_payload <= 1'b0;  end
                    PRIM_HOLD  : begin  rx_dword_en <= 1'b1;                             end
                    PRIM_HOLDA : begin  rx_dword_en <= 1'b1;                             end
                    default    : begin end
                endcase
            end else
                rx_dword_en <= rx_dword_payload;
        end
    end



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// RX data (from PHY layer) : replace CONT
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
always@(posedge clk or negedge link_rstn)
    if (~link_rstn) begin
        rx_pastisprim <= 1'b0;
        rx_conting <= 1'b0;
        rx_prim_en <= 1'b0;
        rx_data_en <= 1'b0;
        rx_data <= '0;
    end else begin
        if(flip) begin
            rx_data_en <= 1'b0;
            if(~rx_dword_en) begin                                      // FIFO has no data
                rx_prim_en <= rx_conting;                               //
            end else if(rx_dword_prim && rx_dword == PRIM_CONT) begin   // CONT primitive
                rx_conting <= rx_pastisprim;                            //   if past is a primitive, going to CONTing mode
                rx_prim_en <= rx_pastisprim;                            //
            end else if(rx_dword_prim) begin                            // other primitive
                rx_pastisprim <= 1'b1;                                  //   set rx_pastisprim=1, indicates if next time we get a CONT primitive, we should repeat the current primitive
                rx_conting <= 1'b0;                                     //   when get a primitive except CONT, exit CONTing
                rx_prim_en <= 1'b1;                                     //   
                rx_data <= rx_dword;                                    //
            end else begin                                              // data
                rx_pastisprim <= 1'b0;                                  //   set rx_pastisprim=1, indicates if next time we get a CONT primitive, it is a invalid CONT because it do not follows another primitive
                rx_prim_en <=  rx_conting;                              //   during CONTing, the data is actually the garbage data that indicates past primitive is repeating
                rx_data_en <= ~rx_conting;                              //   the data is true data only when NOT during CONTing
                rx_data <= rx_dword;                                    //
            end
        end
    end



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// main FSM
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
always@(posedge clk or negedge core_rstn)
    if (~core_rstn) begin
        rx_align_lost_cnt <= '0;
        link_rstn <= 1'b0;
        counter <= 0;
        {tx_prim1, tx_data1} <= '0;
        {rfisb_end, rfisb_en, rfisb_data} <= '0;
        {xfis_done, xfis_err} <= 1'b0;
        xfisbuf_raddr <= '0;
        state <= RESET;
    end else begin
        link_rstn <= state > RESET;
        {rfisb_end, rfisb_en} <= '0;
        {xfis_done, xfis_err} <= 1'b0;
        if(~flip) begin
            {tx_prim1, tx_data1} <= {1'b1, PRIM_ALIGN};
            
            state_next = state;
            
            case (state)
                
                // link initialization //////////////////////////////////////////////////////////////////////////////////////////////////////
                RESET : begin
                    if(rx_locked && counter > 20000000)
                        state_next = WAIT_AFTER_RESET;
                end
                
                WAIT_AFTER_RESET : begin
                    if(counter > 10000)
                        state_next = HANDSHAKE_COMINIT;
                end
                
                HANDSHAKE_COMINIT : begin
                    if(rx_cominit && counter >= 162)
                        state_next = HANDSHAKE_COMWAKE;
                    else if(counter > 1000000)
                        state_next = RESET;
                end
                
                HANDSHAKE_COMWAKE : begin
                    if(rx_comwake && counter >= 155)
                        state_next = WAIT_ELECNIDLE;
                    else if(counter > 1000000)
                        state_next = RESET;
                end
                
                WAIT_ELECNIDLE : begin
                    if(~rx_elecidle && counter > 32)
                        state_next = HOST_DIALTONE;
                    else if(counter > 1000000)
                        state_next = RESET;
                end
                
                HOST_DIALTONE : begin
                    {tx_prim1, tx_data1} <= {1'b0, PRIM_DIALTONE};
                    if(rx_byteisaligned)
                        state_next = WAIT_DEV_SYNC;
                    else if(counter > 1000000)
                        state_next = RESET;
                end
                
                WAIT_DEV_SYNC : begin
                    if(~rx_elecidle && dev_is_synced)
                        state_next = IDLE;
                    else if(counter > 1000000)
                        state_next = RESET;
                end

                // IDLE //////////////////////////////////////////////////////////////////////////////////////////////////////
                IDLE : begin
                    tx_data1 <= PRIM_SYNC;
                    if(rx_prim_en && rx_data == PRIM_X_RDY)
                        state_next = RECV_RDY;
                    else if(~xfis_idle && counter > 45000)
                    //else if(~xfis_idle && counter > 45000000)
                        state_next = SEND_RDY;
                end
                
                // receive FIS //////////////////////////////////////////////////////////////////////////////////////////////////////
                RECV_RDY : begin
                    tx_data1 <= PRIM_R_RDY;
                    if(rx_prim_en && (rx_data == PRIM_EOF || rx_data == PRIM_WTRM || rx_data == PRIM_SYNC) ) begin
                        rfisb_end <= 1'b1;
                        state_next = RECV_ERR;
                    end else if(rx_prim_en && rx_data == PRIM_SOF)
                        state_next = RECV_IP;
                end
                
                RECV_IP : begin
                    tx_data1 <= PRIM_R_IP;
                    if(rx_prim_en && rx_data == PRIM_HOLD) begin
                        tx_data1 <= PRIM_HOLDA;
                    end else if(rx_prim_en && (rx_data == PRIM_EOF || rx_data == PRIM_WTRM || rx_data == PRIM_SYNC) ) begin
                        rfisb_end <= 1'b1;
                        state_next = (r_crc != 0) ? RECV_ERR : RECV_OK;     // this FSM works every 2 clocks. It has enough time to add one additional pipeline stage to check CRC, in other words, this expression will not miss r_crc
                    end else if(rx_data_en) begin
                        rfisb_en <= 1'b1;
                        rfisb_data <= rx_data;
                    end
                end
                
                RECV_OK : begin
                    tx_data1 <= PRIM_R_OK;
                    if(rx_prim_en && (rx_data == PRIM_SYNC || rx_data == PRIM_X_RDY) )
                        state_next = IDLE;
                end
                
                RECV_ERR : begin
                    tx_data1 <= PRIM_R_ERR;
                    if(rx_prim_en && (rx_data == PRIM_SYNC || rx_data == PRIM_X_RDY) )
                        state_next = IDLE;
                end
                
                // send FIS //////////////////////////////////////////////////////////////////////////////////////////////////////
                SEND_RDY : begin
                    tx_data1 <= PRIM_X_RDY;
                    if(rx_prim_en && rx_data == PRIM_X_RDY)              // if device wants to send -> relinquish (give up sending FIS, turn to receive)
                        state_next = RECV_RDY;
                    else if(rx_prim_en && rx_data == PRIM_R_RDY)         // device is ready for receiving
                        state_next = SEND_SOF;
                    else if(counter > 10000000)                          // abort
                        state_next = IDLE;
                end
                
                SEND_SOF : begin
                    tx_data1 <= PRIM_SOF;
                    if(~insert_align)
                        state_next = SEND_FIS;
                end
                
                SEND_FIS : begin
                    if(rx_prim_en && rx_data == PRIM_HOLD) begin
                        tx_data1 <= PRIM_HOLDA;
                    end else if(~insert_align) begin
                        {tx_prim1, tx_data1} <= {1'b0, xfisbuf_rdata};
                        xfisbuf_raddr <= xfisbuf_raddr + 16'd1;
                        if(xfisbuf_raddr >= (xfisbuf_waddr-16'd1) )
                            state_next = SEND_CRC;
                    end
                end
                
                SEND_CRC : begin
                    {tx_prim1, tx_data1} <= {1'b0, (x_crc^x_scramble_res)};
                    if(~insert_align)
                        state_next = SEND_EOF;
                end
                
                SEND_EOF : begin
                    tx_data1 <= PRIM_EOF;
                    if(~insert_align)
                        state_next = SEND_WTRM;
                end
                
                SEND_WTRM : begin
                    tx_data1 <= PRIM_WTRM;
                    if(rx_prim_en && rx_data == PRIM_R_OK) begin
                        xfis_done <= 1'b1;
                        state_next = SEND_END_SYNC;
                    end else if(rx_prim_en && rx_data == PRIM_R_ERR) begin
                        xfis_done <= 1'b1;
                        xfis_err  <= 1'b1;
                        state_next = SEND_END_SYNC;
                    end
                end
                
                SEND_END_SYNC : begin
                    tx_data1 <= PRIM_SYNC;
                    if(rx_prim_en && (rx_data == PRIM_SYNC || rx_data == PRIM_X_RDY) )
                        state_next = IDLE;
                end
                
                default :
                    state_next = RESET;
            endcase
            
            if(state != SEND_FIS) xfisbuf_raddr <= '0;
            
            if(state<IDLE || rx_datain_r == PRIM_ALIGN) begin
                rx_align_lost_cnt <= '0;
            end else begin
                rx_align_lost_cnt <= rx_align_lost_cnt + 24'd1;
                if(rx_align_lost_cnt == '1) state_next = RESET;     // if can't receive ALIGN for a long time, reset FSM. the goal is to support hot-pulgin
            end
            
            if(state>=IDLE && insert_align)                         //
                {tx_prim1, tx_data1} <= {1'b1, PRIM_ALIGN};         // insert ALIGN primitive
            
            counter <= (state == state_next) ? counter+1 : 0;       // if state NOT change, counter increase. This counter indicates a state's duration.
            
            state <= state_next;
        end
    end



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// OOB signal and state signal generating
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
assign rx_pcs_rstn = link_rstn;
always @ (posedge clk or negedge link_rstn)
    if(~link_rstn) begin
        tx_cominit       <= 1'b0;
        tx_comwake       <= 1'b0;
        tx_elecidle      <= 1'b0;
        link_initialized <= 1'b0;
        dev_is_synced    <= 1'b0;
    end else begin
        tx_cominit       <= state == HANDSHAKE_COMINIT && counter < 162;
        tx_comwake       <= state == HANDSHAKE_COMWAKE && counter < 155;
        tx_elecidle      <= state <  HOST_DIALTONE;
        link_initialized <= state >= IDLE;
        if(state < WAIT_ELECNIDLE)
            dev_is_synced <= 1'b0;
        else if(rx_prim_en && rx_data == PRIM_SYNC)
            dev_is_synced <= 1'b1;
    end



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// TX data (to PHY layer) : replace repeat primitives with CONT, shift output (convert DWORD to WORD)
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
generate
if(TX_CONT_ENABLE == "TRUE") begin
    reg         tx_prim2 = 1'b0;
    reg  [31:0] tx_data2 = '0;
    reg  [15:0] tx_dataouth = '0;
    reg  [ 2:0] tx_rep_cnt  = '0;
    reg  [31:0] tx_rep_prim = '0;
    reg  [15:0] tx_cont_scramble     = SCRAMBLER_INIT_VALUE;
    reg  [31:0] tx_cont_scramble_res = SCRAMBLER_RES_INIT_VALUE;
    always @ (posedge clk or negedge link_rstn)
        if(~link_rstn) begin
            {tx_prim2, tx_data2} <= '0;
            {tx_chariskr, tx_dataouth, tx_dataoutr} <= '0;
            tx_rep_cnt  <= '0;
            tx_rep_prim <= '0;
            tx_cont_scramble     <= SCRAMBLER_INIT_VALUE;
            tx_cont_scramble_res <= SCRAMBLER_RES_INIT_VALUE;
        end else begin
            if(~flip) begin
                {tx_prim2, tx_data2} <= {tx_prim1, tx_data1};
                {tx_chariskr, tx_dataoutr} <= {1'b0, tx_dataouth};
            end else begin
                {tx_chariskr, tx_dataouth, tx_dataoutr} <= {tx_prim2, tx_data2};                         // default: do NOT replace any data or primitive
                if( !tx_prim1 || !tx_prim2 || (tx_data1!=tx_data2) || !is_repeatable(tx_data2) ) begin   // if current data is not primitive, or current primitive is not repeatable, or current primitive != next primitive
                    tx_rep_cnt  <= '0;                                                                   //   clear repeat count
                end else if(tx_rep_cnt == '0 || tx_rep_prim != tx_data2) begin                           // if occurs a repeatable primitive for the 1st time
                    tx_rep_cnt  <= 3'd1;                                                                 //   
                    tx_rep_prim <= tx_data2;                                                             //   save this primitive
                end else if(tx_rep_cnt <  REPLACE_PRIM_WITH_CONT_ON_REPEAT_COUNT) begin                  // if repeat count is NOT enough
                    tx_rep_cnt  <= tx_rep_cnt + 3'd1;                                                    //
                end else if(tx_rep_cnt == REPLACE_PRIM_WITH_CONT_ON_REPEAT_COUNT) begin                  // if repeat count is enough and it's the first CONT
                    tx_rep_cnt <= tx_rep_cnt + 3'd1;                                                     //
                    {tx_chariskr, tx_dataouth, tx_dataoutr} <= {1'b1, PRIM_CONT};                        //     replace with CONT for the 1st time
                end else begin                                                                           // if repeat count is enough and it's NOT the first CONT
                    {tx_chariskr, tx_dataouth, tx_dataoutr} <= {1'b0, tx_cont_scramble_res};             //     replace with garbage scramble data
                    {tx_cont_scramble_res, tx_cont_scramble} <= func_scrambler32(tx_cont_scramble);      //     update scrambler
                end
            end
        end
end else begin
    always_comb tx_chariskr = flip ? tx_prim1       : 1'b0           ;
    always_comb tx_dataoutr = flip ? tx_data1[15:0] : tx_data1[31:16];
end
endgenerate



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// TX data (to PHY layer) : output stage
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
always @ (posedge clk) begin
    tx_charisk <= tx_chariskr;
    tx_dataout <= tx_dataoutr;
end



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// RX FIS data (to command layer) :  de-scramble, CRC check, FIS length check : (2<=length<=FIS_LEN_MAX) (including CRC)
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
reg [15:0] rxfisa_len = '0;
always @ (posedge clk or negedge link_rstn)
    if(~link_rstn) begin
        {rfisa_end, rfisa_err, rfisa_en, rfisa_data} <= '0;
        rxfisa_len <= '0;
        r_scramble     <= SCRAMBLER_INIT_VALUE;
        r_scramble_res <= SCRAMBLER_RES_INIT_VALUE;
        r_crc          <= CRC_INIT_VALUE;
    end else begin
        rfisa_en  <= 1'b0;
        rfisa_end <= rfisb_end;
        if(rfisb_end) begin
            rfisa_err <= rfisa_err || (r_crc != 0) || (rxfisa_len < 16'd2);
            rxfisa_len <= '0;
            r_scramble     <= SCRAMBLER_INIT_VALUE;
            r_scramble_res <= SCRAMBLER_RES_INIT_VALUE;
            r_crc          <= CRC_INIT_VALUE;
        end else if(rfisb_en) begin
            if(rxfisa_len < FIS_LEN_MAX) begin
                rfisa_en  <= 1'b1;
                rfisa_err <= 1'b0;
                rxfisa_len <= rxfisa_len + 16'd1;
            end else begin
                rfisa_err <= 1'b1;
            end
            rfisa_data <= rfisb_data^r_scramble_res;
            {r_scramble_res, r_scramble} <= func_scrambler32(r_scramble);   // update scambler
            r_crc <= func_crc32(r_crc, rfisb_data^r_scramble_res);         // update CRC
        end
    end



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// RX FIS data (to command layer) : ring buffer control : the goal is to remove error FIS (CRC error or length invalid)
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
always @ (posedge clk or negedge link_rstn)
    if(~link_rstn) begin
        rfisbuf_wbase <= '0;
        rfisbuf_waddr <= '0;
    end else begin
        if(rfisa_en) begin                                                      // FIS payload or CRC
            rfisbuf_waddr <= rfisbuf_waddr + (RXFIS_BUF_DEPTH_LEVEL)'(1);
            // rfisbuf_data_mem[rfisbuf_waddr  ] <= rfisa_data;
            // rfisbuf_lasterr_mem[rfisbuf_waddr  ] <= 2'b00;
        end else if(rfisa_end & ~rfisa_err) begin                              // FIS NOT error
            rfisbuf_wbase <= rfisbuf_waddr - (RXFIS_BUF_DEPTH_LEVEL)'(1);
            rfisbuf_waddr <= rfisbuf_waddr - (RXFIS_BUF_DEPTH_LEVEL)'(1);
            // rfisbuf_lasterr_mem[rfisbuf_waddr-2] <= 2'b10;
        end else if(rfisa_end &  rfisa_err) begin                              // FIS error
            rfisbuf_wbase <= rfisbuf_wbase + (RXFIS_BUF_DEPTH_LEVEL)'(1);
            rfisbuf_waddr <= rfisbuf_wbase + (RXFIS_BUF_DEPTH_LEVEL)'(1);
            // rfisbuf_lasterr_mem[rfisbuf_wbase  ] <= 2'b11;
        end
    end

always @ (posedge clk)
    if( rfisa_en )
        rfisbuf_data_mem[rfisbuf_waddr] <= rfisa_data;

always @ (posedge clk)
    if( rfisa_en | rfisa_end  )
        rfisbuf_lasterr_mem[ rfisa_en ? rfisbuf_waddr : ((~rfisa_err) ? (rfisbuf_waddr-((RXFIS_BUF_DEPTH_LEVEL)'(2))) : rfisbuf_wbase) ] <= {rfisa_end, rfisa_err};

always @ (posedge clk or negedge link_rstn)
    if(~link_rstn) begin
        rfisbuf_raddr <= '0;
        rfisc_en <= 1'b0;
    end else begin
        rfisc_en <= 1'b0;
        if(rfisbuf_raddr != rfisbuf_wbase) begin
            rfisbuf_raddr <= rfisbuf_raddr + (RXFIS_BUF_DEPTH_LEVEL)'(1);
            rfisc_en <= 1'b1;
        end
    end

always @ (posedge clk)
    rfisc_data <= rfisbuf_data_mem[rfisbuf_raddr];

always @ (posedge clk)
    {rfisc_last, rfisc_err} <= rfisbuf_lasterr_mem[rfisbuf_raddr];

always @ (posedge clk or negedge link_rstn)         // output stage
    if(~link_rstn) begin
        {rfis_tvalid, rfis_tlast, rfis_tdata, rfis_err} <= '0;
    end else begin
        rfis_tvalid <= rfisc_en & ~rfisc_err;
        rfis_tlast  <= rfisc_en & ~rfisc_err & rfisc_last;
        if(rfisc_en & ~rfisc_err) rfis_tdata <= rfisc_data;
        rfis_err    <= rfisc_en & rfisc_err;
    end



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// TX FIS data (from command layer) : add scramble, add CRC, buffer control
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
assign xfis_tready = xfis_idle & link_initialized;
always @ (posedge clk or negedge link_rstn)
    if(~link_rstn) begin
        xfis_idle      <= 1'b1;
        xfisbuf_waddr <= '0;
        x_scramble     <= SCRAMBLER_INIT_VALUE;
        x_scramble_res <= SCRAMBLER_RES_INIT_VALUE;
        x_crc          <= CRC_INIT_VALUE;
    end else begin
        if(xfis_idle) begin
            if(link_initialized & xfis_tvalid) begin
                if(xfisbuf_waddr < (FIS_LEN_MAX-16'd1)) begin
                    xfisbuf_waddr <= xfisbuf_waddr + 16'd1;
                    {x_scramble_res, x_scramble} <= func_scrambler32(x_scramble);  // update scambler
                    x_crc <= func_crc32(x_crc, xfis_tdata);                         // update CRC
                end
                xfis_idle <= ~xfis_tlast;
            end
        end else if(xfis_done) begin                                                 // the main FSM send done
            xfis_idle      <= 1'b1;                                                  //   back to TX_IDLE
            xfisbuf_waddr <= '0;
            x_scramble     <= SCRAMBLER_INIT_VALUE;
            x_scramble_res <= SCRAMBLER_RES_INIT_VALUE;
            x_crc          <= CRC_INIT_VALUE;
        end
    end

always @ (posedge clk)                                                   // TX FIS data (from command layer) : buffer write
    if(xfis_tready && xfis_tvalid)
        xfisbuf_mem[xfisbuf_waddr] <= xfis_tdata ^ x_scramble_res;

always @ (posedge clk)                                                   // TX FIS data (from command layer) : buffer read
    xfisbuf_rdata <= xfisbuf_mem[xfisbuf_raddr];




/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ILA
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//ila_1 ila_i (
//    .clk     ( clk                     ),
//    .probe0  ( state                   ),
//    .probe1  ( rx_charisk_r            ),
//    .probe2  ( rx_datain_r             ),
//    .probe3  ( rx_dword_flip           ),
//    .probe4  ( rx_dword_payload        ),
//    .probe5  ( rx_dword_en             ),
//    .probe6  ( rx_dword_prim           ),
//    .probe7  ( rx_dword                ),
//    .probe8  ( rx_dword_en             ),
//    .probe9  ( rx_dword_prim           ),
//    .probe10 ( rx_dword                ),
//    .probe11 ( tx_prim2                ),
//    .probe12 ( tx_data2                )
//);


endmodule
