
//--------------------------------------------------------------------------------------------------------
// Module  : fpga_uart_sata_example_top
// Type    : synthesizable, FPGA's top
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: a test example for SATA.
//           Host PC -> UART RX -> SATA FIS TX
//           Host PC <- UART TX <- SATA FIS RX
//           you can use Serial Port software (minicom, putty, hyper-terminal or serial assistant) to read and write SATA hard disk
//--------------------------------------------------------------------------------------------------------

module fpga_uart_sata_example_top (
    // fpga clock (connect to clock source on FPGA board)
    input  wire       FPGA_SYSCLK_P, FPGA_SYSCLK_N,
    // reset button
    input  wire       BTN0,
    // LED
    output wire [1:0] LED,        // LED[0]=system_rst_n   LED[1]=link_initialized
    // UART, connect to Host-PC
    output wire       UART_TX,
    input  wire       UART_RX,
    // SATA GT reference clock, connect to clock source on FPGA board
    input  wire       SATA_CLK_P, SATA_CLK_N,  // 150Mhz is required
    // SATA signals, connect to SATA device
    input  wire       SATA0_B_P , SATA0_B_N,   // SATA B+ B-
    output wire       SATA0_A_P , SATA0_A_N    // SATA A+ A-
);


wire        rstn;
wire        cpll_refclk;

wire        clk;

wire        link_initialized;

wire        rfis_tvalid;
wire        rfis_tlast;
wire [31:0] rfis_tdata;
wire        rfis_err;

wire        xfis_tvalid;
wire        xfis_tlast;
wire [31:0] xfis_tdata;
wire        xfis_tready;


assign LED = {link_initialized, rstn};



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Xilinx Clock Wizard IP : generate 60MHz clock for SATA HBA
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
clk_wiz_0 clk_wiz_i (
    .reset                    ( BTN0                                   ),   // reset button (high reset)
    .clk_in1_p                ( FPGA_SYSCLK_P                          ),   // 200MHz in+
    .clk_in1_n                ( FPGA_SYSCLK_N                          ),   // 200MHz in-
    .locked                   ( rstn                                   ),   // clock is locked, use as system reset
    .clk_out1                 ( cpll_refclk                            )    // 60MHz out
);



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// SATA HBA
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
sata_hba_top #(
    .SIM_GT_RESET_SPEEDUP     ( "FALSE"                                )    // Set to "FALSE" while synthesis, set to "TRUE" to speed-up simulation.
) sata_hba_i (
    .rstn                     ( rstn                                   ),   // 0:reset   1:work
    .cpll_refclk              ( cpll_refclk                            ),   // 60MHz clock is required
    // SATA GT reference clock, connect to clock source on FPGA board
    .gt_refclkp               ( SATA_CLK_P                             ),
    .gt_refclkn               ( SATA_CLK_N                             ),
    // SATA signals, connect to SATA device
    .gt_rxp                   ( SATA0_B_P                              ),
    .gt_rxn                   ( SATA0_B_N                              ),
    .gt_txp                   ( SATA0_A_P                              ),
    .gt_txn                   ( SATA0_A_N                              ),
    // user clock output
    .clk                      ( clk                                    ),
    // =1 : link initialized
    .link_initialized         ( link_initialized                       ),
    // to Command layer : RX FIS data stream (AXI-stream liked, without tready handshake, clock domain = clk)
    .rfis_tvalid              ( rfis_tvalid                            ),
    .rfis_tlast               ( rfis_tlast                             ),
    .rfis_tdata               ( rfis_tdata                             ),
    .rfis_err                 ( rfis_err                               ),
    // from Command layer : TX FIS data stream (AXI-stream liked, clock domain = clk)
    .xfis_tvalid              ( xfis_tvalid                            ),
    .xfis_tlast               ( xfis_tlast                             ),
    .xfis_tdata               ( xfis_tdata                             ),
    .xfis_tready              ( xfis_tready                            ),
    .xfis_done                (                                        ),
    .xfis_err                 (                                        )
);



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// SATA RX -> UART TX  (include internal buffer)
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
uart_tx #(
    .CLK_DIV                  ( 1302                                  ),   // 150MHz/115200Hz=1302
    .PARITY                   ( "NONE"                                ),   // "NONE", "ODD" or "EVEN"
    .ASIZE                    ( 15                                    ),   // Specify UART TX buffer depth = 2^15 = 32768
    .DWIDTH                   ( 4                                     ),   // Specify width of tx_data , that is, how many bytes can it input per clock cycle
    .ENDIAN                   ( "LITTLE"                              ),   // "LITTLE" or "BIG"
    .MODE                     ( "HEX"                                 ),   // "RAW", "PRINTABLE", "HEX" or "HEXSPACE"
    .END_OF_DATA              ( ""                                    ),   // Dont send extra byte after each tx_data
    .END_OF_PACK              ( "\n"                                  )    // send extra byte "\n" after each tx_last=1
) uart_tx_i (
    .rstn                     ( rstn                                  ),
    .clk                      ( clk                                   ),
    .tx_data                  ( rfis_err ? 32'hEEEEEEEE : rfis_tdata  ),   // send EEEEEEEE when receive a error RX FIS from SATA (CRC error or illegal length)
    .tx_last                  ( rfis_err |                rfis_tlast  ),
    .tx_en                    ( rfis_err |                rfis_tvalid ),
    .tx_rdy                   (                                       ),
    .o_uart_tx                ( UART_TX                               )
);



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// UART RX -> TX FIS buffer -> SATA TX  (include internal buffer)
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
uart_rx #(
    .CLK_DIV                  ( 1302                                  ),   // 150MHz/115200Hz=1302
    .PARITY                   ( "NONE"                                ),   // "NONE", "ODD" or "EVEN"
    .ASIZE                    ( 15                                    )    // Specify UART RX buffer size = 2^15 = 32768
) uart_rx_i (
    .rstn                     ( rstn                                  ),
    .clk                      ( clk                                   ),
    .i_uart_rx                ( UART_RX                               ),
    .o_tready                 ( xfis_tready                           ),
    .o_tvalid                 ( xfis_tvalid                           ),
    .o_tlast                  ( xfis_tlast                            ),
    .o_tdata                  ( xfis_tdata                            )
);



endmodule



