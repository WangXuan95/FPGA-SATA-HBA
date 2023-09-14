
//--------------------------------------------------------------------------------------------------------
// Module  : sata_hba_top
// Type    : synthesizable, IP's top
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: SATA host (HBA)
//           Supports Xilinx FPGAs with GTH
//           implement simple FIS transfer and receive
//--------------------------------------------------------------------------------------------------------

`timescale 1ns/1ps

module sata_hba_top  #(
    parameter SIM_GT_RESET_SPEEDUP = "FALSE"  // Set to "FALSE" while synthesis, set to "TRUE" to speed-up simulation.
) (     // SATA gen2
    input  wire        rstn,          // 0:reset   1:work
    input  wire        cpll_refclk,   // 60MHz clock is required
    // SATA GT reference clock, connect to clock source on FPGA board
    input  wire        gt_refclkp,    // 150Mhz is required
    input  wire        gt_refclkn,    //
    // SATA signals, connect to SATA device
    input  wire        gt_rxp,        // SATA B+
    input  wire        gt_rxn,        // SATA B-
    output wire        gt_txp,        // SATA A+
    output wire        gt_txn,        // SATA A-
    // user clock output
    output wire        clk,           // 75/150 MHZ user clock
    // =1 : link initialized
    output wire        link_initialized,
    // to Command layer : RX FIS data stream (AXI-stream liked, without tready handshake, clock domain = clk)
    //   example wave :               // |  no data  |  FIS1 (no error)  |  no data  | FIS2 (error) |   no data   |  FIS3 (no error)  |   no data   |
    output wire        rfis_tvalid,   // 000000000000111111111111111111111000000000000000000000000000000000000000011111111111111111111100000000000000     // rfis_tvalid=1 indicate rfis_tdata is valid. rfis_tvalid is always continuous (no bubble) when output a FIS
    output wire        rfis_tlast,    // 000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000100000000000000     // rfis_tlast=1  indicate this data is the last data of a FIS
    output wire [31:0] rfis_tdata,    // XXXXXXXXXXXXDDDDDDDDDDDDDDDDDDDDDXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXDDDDDDDDDDDDDDDDDDDDDXXXXXXXXXXXXXX     // data, little endian : [7:0]->byte0, [15:8]->byte1, [23:16]->byte2, [31:24]->byte3
    output wire        rfis_err,      // 000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000     // indicate a error FIS is detected (CRC error or illegal length), the error FIS do not effect rfis_tvalid, rfis_tlast and rfis_tdata
    // from Command layer : TX FIS data stream (AXI-stream liked, clock domain = clk)
    //   example wave :               // | idle  | write FIS1 to buffer  |  FIS1 transfer in progress (no error) |  idle  |  write FIS2 to buffer |  FIS2 transfer in progress (error)  |  idle  |
    input  wire        xfis_tvalid,   // 000000001111101001110111101111110000000000000000000000000000000000000000000000000111111111111111111111111000000000000000000000000000000000000000000000000     // xfis_tvalid=1 indicate xfis_tdata is valid, that is, user want to write data to internal TX FIS buffer. xfis_tvalid handshake with xfis_tready (data will write successfully to TX FIS buffer only when xfis_tvalid=xfis_tready=1). xfis_tvalid allows continuous (no bubble) or discontinuous (insert bubbles)
    input  wire        xfis_tlast,    // 000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000     // xfis_tlast=1  indicate this data is the last data of a FIS. this FIS will transfer to SATA device in progress after xfis_tlast=1 (xfis_tready turn to 0)
    input  wire [31:0] xfis_tdata,    // XXXXXXXXDDDDDXDXXDDDXDDDDXDDDDDDXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXDDDDDDDDDDDDDDDDDDDDDDDDXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX     // data, little endian : [7:0]->byte0, [15:8]->byte1, [23:16]->byte2, [31:24]->byte3
    output wire        xfis_tready,   // 111111111111111111111111111111110000000000000000000000000000000000000000111111111111111111111111111111111000000000000000000000000000000000000001111111111     // xfis_tready=1 indicate FIS transfer is idle, user is allowed to write data to internal TX FIS buffer. while xfis_tready=0 indicate FIS transfer in progress, user is NOT allowed to write data to TX FIS buffer. xfis_tvalid handshake with xfis_tready (data will write successfully to TX FIS buffer only when xfis_tvalid=xfis_tready=1). xfis_tready will turn to 1 at the next cycle of xfis_done=1
    output wire        xfis_done,     // 000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000010000000000     // xfis_done=1 when FIS transfer progress ending, xfis_done=1. and xfis_tready will turn to 1 at the next cycle.
    output wire        xfis_err       // 000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000     // when xfis_done=1, xfis_err=1 indicates FIS transfer error (the SATA device feedback R_ERR).
);


wire        rx_pcs_rstn;
wire        rx_locked;
wire        rx_cominit;
wire        rx_comwake;
wire        rx_elecidle;
wire        rx_byteisaligned;
wire        tx_cominit;
wire        tx_comwake;
wire        tx_elecidle;

wire        rx_charisk;
wire [15:0] rx_datain;

wire        tx_charisk;
wire [15:0] tx_dataout;

wire        gt_refclk;
wire        gt_txoutclk;
wire        drp_clk;



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// reset delay : set core_rstn=0 for 0.1s when rstn=0
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
reg         core_rstn = 1'b0;
reg  [31:0] core_rst_cnt = 0;
always @ (posedge cpll_refclk or negedge rstn)
    if(~rstn) begin
        core_rstn <= 1'b0;
        core_rst_cnt <= 0;
    end else begin
        if(core_rst_cnt < 6000000) begin
            core_rstn <= 1'b0;
            core_rst_cnt <= core_rst_cnt + 1;
        end else begin
            core_rstn <= 1'b1;
        end
    end



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// clock buffer
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
BUFG bufg_drp_clk ( .I(cpll_refclk), .O(drp_clk) );
BUFG bufg_tx_clk  ( .I(gt_txoutclk), .O(    clk) );



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// GT clock generation
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
IBUFDS_GTE2 ibufds_gte2_gt_refclk (
    .I                          ( gt_refclkp                            ),
    .IB                         ( gt_refclkn                            ),
    .CEB                        ( 1'b0                                  ),
    .O                          ( gt_refclk                             ),
    .ODIV2                      (                                       )
);

//// Note1: if gt_refclk is 150MHz, use it as gt_refclk directly
//// Note2: if gt_refclk is not 150MHz, use Xilinx Clock Wizard to convert it to 150MHz (you should config and add this Clock Wizard IP manually)
// ClockWizard_to_150MHz clk_wiz_to_150mhz_i (
//     .clk_in                     ( ???                                   ),
//     .reset                      ( ???                                   ),
//     .clk_out                    ( ???                                   ),
//     .locked                     ( ???                                   )
// );



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// SATA link and transport layer
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
sata_link_transport #(
    .TX_CONT_ENABLE             ( "FALSE"                               )
) sata_link_transport_i (
    // driving clock and reset
    .core_rstn                  ( core_rstn                             ),
    .clk                        ( clk                                   ),
    // =1 : link initialized
    .link_initialized           ( link_initialized                      ),
    // Link<->PHY : control and OOB
    .rx_pcs_rstn                ( rx_pcs_rstn                           ),
    .rx_locked                  ( rx_locked                             ),
    .rx_cominit                 ( rx_cominit                            ),
    .rx_comwake                 ( rx_comwake                            ),
    .rx_elecidle                ( rx_elecidle                           ),
    .rx_byteisaligned           ( rx_byteisaligned                      ),
    .tx_cominit                 ( tx_cominit                            ),
    .tx_comwake                 ( tx_comwake                            ),
    .tx_elecidle                ( tx_elecidle                           ),
    // PHY->Link : RX data (clock domain = clk)
    .rx_charisk                 ( rx_charisk                            ),
    .rx_datain                  ( rx_datain                             ),
    // PHY<-Link : TX data (clock domain = clk)
    .tx_charisk                 ( tx_charisk                            ),
    .tx_dataout                 ( tx_dataout                            ),
    // Transport->Command : RX FIS data stream (AXI-stream liked, without tready handshake, clock domain = clk)
    .rfis_tvalid                ( rfis_tvalid                           ),
    .rfis_tlast                 ( rfis_tlast                            ),
    .rfis_tdata                 ( rfis_tdata                            ),
    .rfis_err                   ( rfis_err                              ),
    // Transport<-Command : TX FIS data stream (AXI-stream liked, clock domain = clk)
    .xfis_tvalid                ( xfis_tvalid                           ),
    .xfis_tlast                 ( xfis_tlast                            ),
    .xfis_tdata                 ( xfis_tdata                            ),
    .xfis_tready                ( xfis_tready                           ),
    .xfis_done                  ( xfis_done                             ),
    .xfis_err                   ( xfis_err                              )
);



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// SATA PHY : GTH
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
sata_gth #(
    .SIM_GT_RESET_SPEEDUP       ( SIM_GT_RESET_SPEEDUP                  )
) sata_gth_i (
    .GTREFCLK0_COMMON_IN        ( gt_refclk                             ),
    .QPLLLOCKDETCLK_IN          ( cpll_refclk                           ),
    .QPLLRESET_IN               ( ~core_rstn                            ),
    .CPLLLOCK_OUT               ( rx_locked                             ),
    .CPLLLOCKDETCLK_IN          ( cpll_refclk                           ),
    .CPLLRESET_IN               ( ~core_rstn                            ),
    .GTREFCLK0_IN               ( gt_refclk                             ),
    .DRPCLK_IN                  ( drp_clk                               ),
    .RX_PCS_RESETN              ( rx_pcs_rstn                           ),
    .RXUSERRDY_IN               ( rx_pcs_rstn                           ),
    .RXUSRCLK_IN                ( clk                                   ),
    .RXDATA_OUT                 ( rx_datain                             ),
    .RXN_IN                     ( gt_rxn                                ),
    .RXP_IN                     ( gt_rxp                                ),
    .RXBYTEISALIGNED_OUT        ( rx_byteisaligned                      ),
    .RXOUTCLK_OUT               (                                       ),
    .RXCOMSASDET_OUT            (                                       ),
    .RXCOMINITDET_OUT           ( rx_cominit                            ),
    .RXCOMWAKEDET_OUT           ( rx_comwake                            ),
    .RXELECIDLE_OUT             ( rx_elecidle                           ),
    .RXCHARISK_OUT              ( rx_charisk                            ),
    .GTTXRESET_IN               ( ~(core_rstn & rx_locked)              ),
    .TXUSERRDY_IN               (   core_rstn & rx_locked               ),
    .TXUSRCLK_IN                ( clk                                   ),
    .TXELECIDLE_IN              ( tx_elecidle                           ),
    .TXDATA_IN                  ( tx_dataout                            ),
    .TXN_OUT                    ( gt_txn                                ),
    .TXP_OUT                    ( gt_txp                                ),
    .TXOUTCLK_OUT               ( gt_txoutclk                           ),
    .TXCOMSAS_IN                ( 1'b0                                  ),
    .TXCOMINIT_IN               ( tx_cominit                            ),
    .TXCOMWAKE_IN               ( tx_comwake                            ),
    .TXCHARISK_IN               ( tx_charisk                            )
);



endmodule
