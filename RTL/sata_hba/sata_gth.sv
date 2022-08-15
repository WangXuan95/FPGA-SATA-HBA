
//--------------------------------------------------------------------------------------------------------
// Module  : sata_gth
// Type    : synthesizable, IP's sub-module
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: SATA host (HBA) PHY layer using GTH on Xilinx FPGA
//--------------------------------------------------------------------------------------------------------

`timescale 1ns/1ps

module sata_gth #(
    parameter SIM_GT_RESET_SPEEDUP = "FALSE"  // Set to "FALSE" while synthesis, set to "TRUE" to speed-up simulation.
) (
    //-------------------- Common Block  - Ref Clock Ports ---------------------
    input  wire         GTREFCLK0_COMMON_IN,
    //----------------------- Common Block - QPLL Ports ------------------------
    input  wire         QPLLLOCKDETCLK_IN,
    input  wire         QPLLRESET_IN,
    //------------------------------- CPLL Ports -------------------------------
    output wire         CPLLLOCK_OUT,
    input  wire         CPLLLOCKDETCLK_IN,
    input  wire         CPLLRESET_IN,
    //------------------------ Channel - Clocking Ports ------------------------
    input  wire         GTREFCLK0_IN,
    //-------------------------- Channel - DRP Ports  --------------------------
    input  wire         DRPCLK_IN,
    //------------------- GT RX PCS reset_n ------------------------------------ 
    input  wire         RX_PCS_RESETN,
    //------------------- RX Initialization and Reset Ports --------------------
    input  wire         RXUSERRDY_IN,
    //---------------- Receive Ports - FPGA RX Interface Ports -----------------
    input  wire         RXUSRCLK_IN,
    //---------------- Receive Ports - FPGA RX interface Ports -----------------
    output wire [15:0]  RXDATA_OUT,
    //---------------------- Receive Ports - RX AFE Ports ----------------------
    input  wire         RXN_IN,
    input  wire         RXP_IN,
    //------------ Receive Ports - RX Byte and Word Alignment Ports ------------
    output wire         RXBYTEISALIGNED_OUT,
    //------------- Receive Ports - RX Fabric Output Control Ports -------------
    output wire         RXOUTCLK_OUT,
    //----------------- Receive Ports - RX OOB Signaling ports -----------------
    output wire         RXCOMSASDET_OUT,
    output wire         RXCOMINITDET_OUT,
    output wire         RXCOMWAKEDET_OUT,
    output wire         RXELECIDLE_OUT,
    //----------------- Receive Ports - RX8B/10B Decoder Ports -----------------
    output wire         RXCHARISK_OUT,
    //------------------- TX Initialization and Reset Ports --------------------
    input  wire         GTTXRESET_IN,
    input  wire         TXUSERRDY_IN,
    //---------------- Transmit Ports - FPGA TX Interface Ports ----------------
    input  wire         TXUSRCLK_IN,
    //------------------- Transmit Ports - PCI Express Ports -------------------
    input  wire         TXELECIDLE_IN,
    //---------------- Transmit Ports - TX Data Path interface -----------------
    input  wire [15:0]  TXDATA_IN,
    //-------------- Transmit Ports - TX Driver and OOB signaling --------------
    output wire         TXN_OUT,
    output wire         TXP_OUT,
    //--------- Transmit Ports - TX Fabric Clock Output Control Ports ----------
    output wire         TXOUTCLK_OUT,
    //---------------- Transmit Ports - TX OOB signalling Ports ----------------
    input  wire         TXCOMSAS_IN,
    input  wire         TXCOMINIT_IN,
    input  wire         TXCOMWAKE_IN,
    //--------- Transmit Transmit Ports - 8b10b Encoder Control Ports ----------
    input  wire         TXCHARISK_IN
);


localparam TXSYNC_OVRD_IN      = 1'b0;
localparam TXSYNC_MULTILANE_IN = 1'b0;

localparam QPLL_FBDIV_TOP =  16;

localparam QPLL_FBDIV_IN  =   (QPLL_FBDIV_TOP == 16)  ? 10'b0000100000 : 
                              (QPLL_FBDIV_TOP == 20)  ? 10'b0000110000 :
                              (QPLL_FBDIV_TOP == 32)  ? 10'b0001100000 :
                              (QPLL_FBDIV_TOP == 40)  ? 10'b0010000000 :
                              (QPLL_FBDIV_TOP == 64)  ? 10'b0011100000 :
                              (QPLL_FBDIV_TOP == 66)  ? 10'b0101000000 :
                              (QPLL_FBDIV_TOP == 80)  ? 10'b0100100000 :
                              (QPLL_FBDIV_TOP == 100) ? 10'b0101110000 :
                                                        10'b0000000000;

localparam QPLL_FBDIV_RATIO = (QPLL_FBDIV_TOP == 16)  ? 1'b1 : 
                              (QPLL_FBDIV_TOP == 20)  ? 1'b1 :
                              (QPLL_FBDIV_TOP == 32)  ? 1'b1 :
                              (QPLL_FBDIV_TOP == 40)  ? 1'b1 :
                              (QPLL_FBDIV_TOP == 64)  ? 1'b1 :
                              (QPLL_FBDIV_TOP == 66)  ? 1'b0 :
                              (QPLL_FBDIV_TOP == 80)  ? 1'b1 :
                              (QPLL_FBDIV_TOP == 100) ? 1'b1 :
                                                        1'b1;



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// DRP operation
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

reg         gtrxreset1;
reg         gtrxreset2;
wire        rxpmaresetdone0;
wire        rxpmaresetdone1;
wire        rxpmaresetdone2;
reg         rxpmaresetdone3;

reg         gtrxreset_o;

reg  [15:0] drp_rddata;
reg         drp_op_done;
reg         drpen_i;
reg         drpwe_i;
reg  [15:0] drpdi_i;
wire [15:0] drpdo_i;
wire        drprdy_i;

enum logic [2:0] {IDLE, DRP_RD, WAIT_RD_DATA, WR_16, WAIT_WR_DONE1, WAIT_PMA_RESET, WR_20, WAIT_WR_DONE2} state;

(* shreg_extract = "no", ASYNC_REG = "TRUE" *) FD #( .INIT (1'b0) ) rxpmaresetdone_sync1 ( .C(DRPCLK_IN), .D(rxpmaresetdone0), .Q(rxpmaresetdone1) );

(* shreg_extract = "no", ASYNC_REG = "TRUE" *) FD #( .INIT (1'b0) ) rxpmaresetdone_sync2 ( .C(DRPCLK_IN), .D(rxpmaresetdone1), .Q(rxpmaresetdone2) );

always @ (posedge DRPCLK_IN or posedge CPLLRESET_IN)
    if (CPLLRESET_IN) begin
        {gtrxreset2, gtrxreset1} <= 2'b0;
        rxpmaresetdone3 <= 1'b0;
    end else begin
        {gtrxreset2, gtrxreset1} <= {gtrxreset1, ~RX_PCS_RESETN};
        rxpmaresetdone3 <= rxpmaresetdone2;
    end

always @ (posedge DRPCLK_IN or posedge CPLLRESET_IN)
    if (CPLLRESET_IN) begin
        gtrxreset_o <= 1'b0;
        drp_rddata <= 16'b0;
        state <= IDLE;
    end else begin
        gtrxreset_o <= 1'b0;
        case (state)
            IDLE : begin
                if (gtrxreset2)
                    state <= DRP_RD;
                else
                    state <= IDLE;
            end
            DRP_RD : begin
                gtrxreset_o <= 1'b1;
                state <= WAIT_RD_DATA;
            end
            WAIT_RD_DATA : begin
                gtrxreset_o <= 1'b1;
                if (drprdy_i) begin
                    drp_rddata <= drpdo_i;
                    state <= WR_16;
                end else begin
                    state <= WAIT_RD_DATA;
                end
            end
            WR_16 : begin
                gtrxreset_o <= 1'b1;
                state <= WAIT_WR_DONE1;
            end
            WAIT_WR_DONE1 : begin
                gtrxreset_o <= 1'b1;
                if (drprdy_i)
                    state <= WAIT_PMA_RESET;
                else
                    state <= WAIT_WR_DONE1;
            end
            WAIT_PMA_RESET : begin
                gtrxreset_o <= gtrxreset2;
                if (!rxpmaresetdone2 & rxpmaresetdone3)
                    state <= WR_20;
                else
                    state <= WAIT_PMA_RESET;
            end
            WR_20 : begin
                state <= WAIT_WR_DONE2;
            end
            WAIT_WR_DONE2 : begin
                if (drprdy_i)
                    state <= IDLE;
                else
                    state <= WAIT_WR_DONE2;
            end
        endcase
    end

always @ (*) begin       // drives DRP interface
    drpen_i = 1'b0;
    drpwe_i = 1'b0;
    drpdi_i = 16'b0;
    if(~drp_op_done) begin
        case (state)
            DRP_RD : begin
                drpen_i = 1'b1;
            end
            WR_16 : begin
                drpen_i = 1'b1;
                drpwe_i = 1'b1;
                drpdi_i = {drp_rddata[15:12], 1'b0, drp_rddata[10:0]};
            end
            WR_20 : begin
                drpen_i = 1'b1;
                drpwe_i = 1'b1;
                drpdi_i = drp_rddata;
            end
        endcase
    end
end

always @ (posedge DRPCLK_IN or negedge RX_PCS_RESETN)
    if (!RX_PCS_RESETN) begin
        drp_op_done <= 1'b0;
    end else begin
        if(state == WAIT_WR_DONE2 && drprdy_i)
            drp_op_done <= 1'b1;
    end



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// GT common
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
wire        qpllclk_i;
wire        qpllrefclk_i;

GTHE2_COMMON #(
    //----------------Simulation attributes----------------
    .SIM_RESET_SPEEDUP              ( SIM_GT_RESET_SPEEDUP                               ),
    .SIM_QPLLREFCLK_SEL             ( 3'b001                                             ),
    .SIM_VERSION                    ( "2.0"                                              ),
    //----------------COMMON BLOCK Attributes---------------
    .BIAS_CFG                       ( 64'h0000040000001050                               ),
    .COMMON_CFG                     ( 32'h00000000                                       ),
    .QPLL_CFG                       ( 27'h04801C7                                        ),
    .QPLL_CLKOUT_CFG                ( 4'b1111                                            ),
    .QPLL_COARSE_FREQ_OVRD          ( 6'b010000                                          ),
    .QPLL_COARSE_FREQ_OVRD_EN       ( 1'b0                                               ),
    .QPLL_CP                        ( 10'b0000011111                                     ),
    .QPLL_CP_MONITOR_EN             ( 1'b0                                               ),
    .QPLL_DMONITOR_SEL              ( 1'b0                                               ),
    .QPLL_FBDIV                     ( QPLL_FBDIV_IN                                      ),
    .QPLL_FBDIV_MONITOR_EN          ( 1'b0                                               ),
    .QPLL_FBDIV_RATIO               ( QPLL_FBDIV_RATIO                                   ),
    .QPLL_INIT_CFG                  ( 24'h000006                                         ),
    .QPLL_LOCK_CFG                  ( 16'h05E8                                           ),
    .QPLL_LPF                       ( 4'b1111                                            ),
    .QPLL_REFCLK_DIV                ( 1                                                  ),
    .RSVD_ATTR0                     ( 16'h0000                                           ),
    .RSVD_ATTR1                     ( 16'h0000                                           ),
    .QPLL_RP_COMP                   ( 1'b0                                               ),
    .QPLL_VTRL_RESET                ( 2'b00                                              ),
    .RCAL_CFG                       ( 2'b00                                              )
) gthe2_common_0_i (
    //----------- Common Block  - Dynamic Reconfiguration Port (DRP) -----------
    .DRPADDR                        ( 8'h0                                               ),
    .DRPCLK                         ( 1'b0                                               ),
    .DRPDI                          ( 16'h0                                              ),
    .DRPDO                          (                                                    ),
    .DRPEN                          ( 1'b0                                               ),
    .DRPRDY                         (                                                    ),
    .DRPWE                          ( 1'b0                                               ),
    //-------------------- Common Block  - Ref Clock Ports ---------------------
    .GTGREFCLK                      ( 1'b0                                               ),
    .GTNORTHREFCLK0                 ( 1'b0                                               ),
    .GTNORTHREFCLK1                 ( 1'b0                                               ),
    .GTREFCLK0                      ( GTREFCLK0_COMMON_IN                                ),
    .GTREFCLK1                      ( 1'b0                                               ),
    .GTSOUTHREFCLK0                 ( 1'b0                                               ),
    .GTSOUTHREFCLK1                 ( 1'b0                                               ),
    //----------------------- Common Block -  QPLL Ports -----------------------
    .QPLLDMONITOR                   (                                                    ),
    //--------------------- Common Block - Clocking Ports ----------------------
    .QPLLOUTCLK                     ( qpllclk_i                                          ),
    .QPLLOUTREFCLK                  ( qpllrefclk_i                                       ),
    .REFCLKOUTMONITOR               (                                                    ),
    //----------------------- Common Block - QPLL Ports ------------------------
    .BGRCALOVRDENB                  ( 1'b1                                               ),
    .PMARSVDOUT                     (                                                    ),
    .QPLLFBCLKLOST                  (                                                    ),
    .QPLLLOCK                       (                                                    ),
    .QPLLLOCKDETCLK                 ( QPLLLOCKDETCLK_IN                                  ),
    .QPLLLOCKEN                     ( 1'b1                                               ),
    .QPLLOUTRESET                   ( 1'b0                                               ),
    .QPLLPD                         ( 1'b0                                               ),
    .QPLLREFCLKLOST                 (                                                    ),
    .QPLLREFCLKSEL                  ( 3'b001                                             ),
    .QPLLRESET                      ( QPLLRESET_IN                                       ),
    .QPLLRSVD1                      ( 16'h0                                              ),
    .QPLLRSVD2                      ( 5'b11111),
    //------------------------------- QPLL Ports -------------------------------
    .BGBYPASSB                      ( 1'b1                                               ),
    .BGMONITORENB                   ( 1'b1                                               ),
    .BGPDB                          ( 1'b1                                               ),
    .BGRCALOVRD                     ( 5'h0                                               ),
    .PMARSVD                        ( 8'h0                                               ),
    .RCALENB                        ( 1'b1                                               )
);



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// GT channel
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
wire    [47:0]  rxdata_float_i;
wire    [ 6:0]  rxcharisk_float_i;

GTHE2_CHANNEL #(
    //_______________________ Simulation-Only Attributes __________________
    .SIM_RECEIVER_DETECT_PASS       ( "TRUE"                                             ),
    .SIM_TX_EIDLE_DRIVE_LEVEL       ( "X"                                                ), 
    .SIM_RESET_SPEEDUP              ( SIM_GT_RESET_SPEEDUP                               ),
    .SIM_CPLLREFCLK_SEL             ( 3'b001                                             ),
    .SIM_VERSION                    ( "2.0"                                              ),
    //----------------RX Byte and Word Alignment Attributes---------------
    .ALIGN_COMMA_DOUBLE             ( "FALSE"                                            ),
    .ALIGN_COMMA_ENABLE             ( 10'b1111111111                                     ),
    .ALIGN_COMMA_WORD               ( 1                                                  ),
    .ALIGN_MCOMMA_DET               ( "TRUE"                                             ),
    .ALIGN_MCOMMA_VALUE             ( 10'b1010000011                                     ),
    .ALIGN_PCOMMA_DET               ( "TRUE"                                             ),
    .ALIGN_PCOMMA_VALUE             ( 10'b0101111100                                     ),
    .SHOW_REALIGN_COMMA             ( "TRUE"                                             ),
    .RXSLIDE_AUTO_WAIT              ( 7                                                  ),
    .RXSLIDE_MODE                   ( "OFF"                                              ),
    .RX_SIG_VALID_DLY               ( 10                                                 ),
    //----------------RX 8B/10B Decoder Attributes---------------
    .RX_DISPERR_SEQ_MATCH           ( "TRUE"                                             ),
    .DEC_MCOMMA_DETECT              ( "TRUE"                                             ),
    .DEC_PCOMMA_DETECT              ( "TRUE"                                             ),
    .DEC_VALID_COMMA_ONLY           ( "FALSE"                                            ),
    //----------------------RX Clock Correction Attributes----------------------
    .CBCC_DATA_SOURCE_SEL           ( "DECODED"                                          ),
    .CLK_COR_SEQ_2_USE              ( "FALSE"                                            ),
    .CLK_COR_KEEP_IDLE              ( "FALSE"                                            ),
    .CLK_COR_MAX_LAT                ( 9                                                  ),
    .CLK_COR_MIN_LAT                ( 7                                                  ),
    .CLK_COR_PRECEDENCE             ( "TRUE"                                             ),
    .CLK_COR_REPEAT_WAIT            ( 0                                                  ),
    .CLK_COR_SEQ_LEN                ( 1                                                  ),
    .CLK_COR_SEQ_1_ENABLE           ( 4'b1111                                            ),
    .CLK_COR_SEQ_1_1                ( 10'b0100000000                                     ),
    .CLK_COR_SEQ_1_2                ( 10'b0000000000                                     ),
    .CLK_COR_SEQ_1_3                ( 10'b0000000000                                     ),
    .CLK_COR_SEQ_1_4                ( 10'b0000000000                                     ),
    .CLK_CORRECT_USE                ( "FALSE"                                            ),
    .CLK_COR_SEQ_2_ENABLE           ( 4'b1111                                            ),
    .CLK_COR_SEQ_2_1                ( 10'b0100000000                                     ),
    .CLK_COR_SEQ_2_2                ( 10'b0000000000                                     ),
    .CLK_COR_SEQ_2_3                ( 10'b0000000000                                     ),
    .CLK_COR_SEQ_2_4                ( 10'b0000000000                                     ),
    //----------------------RX Channel Bonding Attributes----------------------
    .CHAN_BOND_KEEP_ALIGN           ( "FALSE"                                            ),
    .CHAN_BOND_MAX_SKEW             ( 1                                                  ),
    .CHAN_BOND_SEQ_LEN              ( 1                                                  ),
    .CHAN_BOND_SEQ_1_1              ( 10'b0000000000                                     ),
    .CHAN_BOND_SEQ_1_2              ( 10'b0000000000                                     ),
    .CHAN_BOND_SEQ_1_3              ( 10'b0000000000                                     ),
    .CHAN_BOND_SEQ_1_4              ( 10'b0000000000                                     ),
    .CHAN_BOND_SEQ_1_ENABLE         ( 4'b1111                                            ),
    .CHAN_BOND_SEQ_2_1              ( 10'b0000000000                                     ),
    .CHAN_BOND_SEQ_2_2              ( 10'b0000000000                                     ),
    .CHAN_BOND_SEQ_2_3              ( 10'b0000000000                                     ),
    .CHAN_BOND_SEQ_2_4              ( 10'b0000000000                                     ),
    .CHAN_BOND_SEQ_2_ENABLE         ( 4'b1111                                            ),
    .CHAN_BOND_SEQ_2_USE            ( "FALSE"                                            ),
    .FTS_DESKEW_SEQ_ENABLE          ( 4'b1111                                            ),
    .FTS_LANE_DESKEW_CFG            ( 4'b1111                                            ),
    .FTS_LANE_DESKEW_EN             ( "FALSE"                                            ),
    //-------------------------RX Margin Analysis Attributes----------------------------
    .ES_CONTROL                     ( 6'b000000                                          ),
    .ES_ERRDET_EN                   ( "FALSE"                                            ),
    .ES_EYE_SCAN_EN                 ( "TRUE"                                             ),
    .ES_HORZ_OFFSET                 ( 12'h000                                            ),
    .ES_PMA_CFG                     ( 10'b0000000000                                     ),
    .ES_PRESCALE                    ( 5'b00000                                           ),
    .ES_QUALIFIER                   ( 80'h00000000000000000000                           ),
    .ES_QUAL_MASK                   ( 80'h00000000000000000000                           ),
    .ES_SDATA_MASK                  ( 80'h00000000000000000000                           ),
    .ES_VERT_OFFSET                 ( 9'b000000000                                       ),
    //-----------------------FPGA RX Interface Attributes-------------------------
    .RX_DATA_WIDTH                  ( 20                                                 ),
    //-------------------------PMA Attributes----------------------------
    .OUTREFCLK_SEL_INV              ( 2'b11                                              ),
    .PMA_RSV                        ( 32'b00000000000000000000000010000000               ),
    .PMA_RSV2                       ( 32'h1C00000A                                       ),
    .PMA_RSV3                       ( 2'b00                                              ),
    .PMA_RSV4                       ( 15'h0008                                           ),
    .RX_BIAS_CFG                    ( 24'b000011000000000000010000                       ),
    .DMONITOR_CFG                   ( 24'h000A00                                         ),
    .RX_CM_SEL                      ( 2'b11                                              ), //(2'b01), original value 01
    .RX_CM_TRIM                     ( 4'b1010                                            ), //(4'b1010), original value 4'b0101
    .RX_DEBUG_CFG                   ( 14'b00000000000000                                 ),
    .RX_OS_CFG                      ( 13'b0000010000000                                  ),
    .TERM_RCAL_CFG                  ( 15'b100001000010000                                ),
    .TERM_RCAL_OVRD                 ( 3'b000                                             ),
    .TST_RSV                        ( 32'h00000000                                       ),
    .RX_CLK25_DIV                   ( 6                                                  ),
    .TX_CLK25_DIV                   ( 6                                                  ),
    .UCODEER_CLR                    ( 1'b0                                               ),
    //-------------------------PCI Express Attributes----------------------------
    .PCS_PCIE_EN                    ( "FALSE"                                            ),
    //-------------------------PCS Attributes----------------------------
    .PCS_RSVD_ATTR                  ( 48'h000000000100                                   ), //original value was 0
    //-----------RX Buffer Attributes------------
    .RXBUF_ADDR_MODE                ( "FAST"                                             ),
    .RXBUF_EIDLE_HI_CNT             ( 4'b1000                                            ),
    .RXBUF_EIDLE_LO_CNT             ( 4'b0000                                            ),
    .RXBUF_EN                       ( "TRUE"                                             ),
    .RX_BUFFER_CFG                  ( 6'b000000                                          ),
    .RXBUF_RESET_ON_CB_CHANGE       ( "TRUE"                                             ),
    .RXBUF_RESET_ON_COMMAALIGN      ( "FALSE"                                            ),
    .RXBUF_RESET_ON_EIDLE           ( "FALSE"                                            ),
    .RXBUF_RESET_ON_RATE_CHANGE     ( "TRUE"                                             ),
    .RXBUFRESET_TIME                ( 5'b00001                                           ),
    .RXBUF_THRESH_OVFLW             ( 61                                                 ),
    .RXBUF_THRESH_OVRD              ( "FALSE"                                            ),
    .RXBUF_THRESH_UNDFLW            ( 4                                                  ),
    .RXDLY_CFG                      ( 16'h001F                                           ),
    .RXDLY_LCFG                     ( 9'h030                                             ),
    .RXDLY_TAP_CFG                  ( 16'h0000                                           ),
    .RXPH_CFG                       ( 24'hC00002                                         ),
    .RXPHDLY_CFG                    ( 24'h084020                                         ),
    .RXPH_MONITOR_SEL               ( 5'b00000                                           ),
    .RX_XCLK_SEL                    ( "RXREC"                                            ),
    .RX_DDI_SEL                     ( 6'b000000                                          ),
    .RX_DEFER_RESET_BUF_EN          ( "TRUE"                                             ),
    //---------------------CDR Attributes-------------------------
    //For GTX only: Display Port, HBR/RBR- set RXCDR_CFG=72'h0380008bff40200008
    //For GTX only: Display Port, HBR2 -   set RXCDR_CFG=72'h038C008bff20200010
    .RXCDR_CFG                      ( 83'h0002007FE1000C2200018                          ), //(83'h0_0008_07FE_0800_C8A0_8118)
    .RXCDR_FR_RESET_ON_EIDLE        ( 1'b0                                               ),
    .RXCDR_HOLD_DURING_EIDLE        ( 1'b0                                               ),
    .RXCDR_PH_RESET_ON_EIDLE        ( 1'b0                                               ),
    .RXCDR_LOCK_CFG                 ( 6'b010101                                          ),
    //-----------------RX Initialization and Reset Attributes-------------------
    .RXCDRFREQRESET_TIME            ( 5'b00001                                           ),
    .RXCDRPHRESET_TIME              ( 5'b00001                                           ),
    .RXISCANRESET_TIME              ( 5'b00001                                           ),
    .RXPCSRESET_TIME                ( 5'b00001                                           ),
    .RXPMARESET_TIME                ( 5'b00011                                           ),
    //-----------------RX OOB Signaling Attributes-------------------
    .RXOOB_CFG                      ( 7'b0000110                                         ),
    //-----------------------RX Gearbox Attributes---------------------------
    .RXGEARBOX_EN                   ( "FALSE"                                            ),
    .GEARBOX_MODE                   ( 3'b000                                             ),
    //-----------------------PRBS Detection Attribute-----------------------
    .RXPRBS_ERR_LOOPBACK            ( 1'b0                                               ),
    //-----------Power-Down Attributes----------
    .PD_TRANS_TIME_FROM_P2          ( 12'h03c                                            ),
    .PD_TRANS_TIME_NONE_P2          ( 8'h3c                                              ),
    .PD_TRANS_TIME_TO_P2            ( 8'h64                                              ),
    //-----------RX OOB Signaling Attributes----------
    .SAS_MAX_COM                    ( 64                                                 ),
    .SAS_MIN_COM                    ( 36                                                 ),
    .SATA_BURST_SEQ_LEN             ( 4'b1111                                            ),
    .SATA_BURST_VAL                 ( 3'b100                                             ),
    .SATA_EIDLE_VAL                 ( 3'b100                                             ),
    .SATA_MAX_BURST                 ( 8                                                  ),
    .SATA_MAX_INIT                  ( 21                                                 ),
    .SATA_MAX_WAKE                  ( 7                                                  ),
    .SATA_MIN_BURST                 ( 4                                                  ),
    .SATA_MIN_INIT                  ( 12                                                 ),
    .SATA_MIN_WAKE                  ( 4                                                  ),
    //-----------RX Fabric Clock Output Control Attributes----------
    .TRANS_TIME_RATE                ( 8'h0E                                              ),
    //------------TX Buffer Attributes----------------
    .TXBUF_EN                       ( "TRUE"                                             ),
    .TXBUF_RESET_ON_RATE_CHANGE     ( "TRUE"                                             ),
    .TXDLY_CFG                      ( 16'h001F                                           ),
    .TXDLY_LCFG                     ( 9'h030                                             ),
    .TXDLY_TAP_CFG                  ( 16'h0000                                           ),
    .TXPH_CFG                       ( 16'h0780                                           ),
    .TXPHDLY_CFG                    ( 24'h084020                                         ),
    .TXPH_MONITOR_SEL               ( 5'b00000                                           ),
    .TX_XCLK_SEL                    ( "TXOUT"                                            ),
    //-----------------------FPGA TX Interface Attributes-------------------------
    .TX_DATA_WIDTH                  ( 20                                                 ),
    //-----------------------TX Configurable Driver Attributes-------------------------
    .TX_DEEMPH0                     ( 6'b000000                                          ),
    .TX_DEEMPH1                     ( 6'b000000                                          ),
    .TX_EIDLE_ASSERT_DELAY          ( 3'b110                                             ),
    .TX_EIDLE_DEASSERT_DELAY        ( 3'b100                                             ),
    .TX_LOOPBACK_DRIVE_HIZ          ( "FALSE"                                            ),
    .TX_MAINCURSOR_SEL              ( 1'b0                                               ),
    .TX_DRIVE_MODE                  ( "DIRECT"                                           ),
    .TX_MARGIN_FULL_0               ( 7'b1001110                                         ),
    .TX_MARGIN_FULL_1               ( 7'b1001001                                         ),
    .TX_MARGIN_FULL_2               ( 7'b1000101                                         ),
    .TX_MARGIN_FULL_3               ( 7'b1000010                                         ),
    .TX_MARGIN_FULL_4               ( 7'b1000000                                         ),
    .TX_MARGIN_LOW_0                ( 7'b1000110                                         ),
    .TX_MARGIN_LOW_1                ( 7'b1000100                                         ),
    .TX_MARGIN_LOW_2                ( 7'b1000010                                         ),
    .TX_MARGIN_LOW_3                ( 7'b1000000                                         ),
    .TX_MARGIN_LOW_4                ( 7'b1000000                                         ),
    //-----------------------TX Gearbox Attributes--------------------------
    .TXGEARBOX_EN                   ( "FALSE"                                            ),
    //-----------------------TX Initialization and Reset Attributes--------------------------
    .TXPCSRESET_TIME                ( 5'b00001                                           ),
    .TXPMARESET_TIME                ( 5'b00001                                           ),
    //-----------------------TX Receiver Detection Attributes--------------------------
    .TX_RXDETECT_CFG                ( 14'h1832                                           ),
    .TX_RXDETECT_REF                ( 3'b100                                             ),
    //--------------------------CPLL Attributes----------------------------
    .CPLL_CFG                       ( 29'h00BC07DC                                       ),
    .CPLL_FBDIV                     ( 4                                                  ),
    .CPLL_FBDIV_45                  ( 5                                                  ),
    .CPLL_INIT_CFG                  ( 24'h00001E                                         ),
    .CPLL_LOCK_CFG                  ( 16'h01E8                                           ),
    .CPLL_REFCLK_DIV                ( 1                                                  ),
    .RXOUT_DIV                      ( 2                                                  ),
    .TXOUT_DIV                      ( 2                                                  ),
    .SATA_CPLL_CFG                  ( "VCO_3000MHZ"                                      ),
    //------------RX Initialization and Reset Attributes-------------
    .RXDFELPMRESET_TIME             ( 7'b0001111                                         ),
    //------------RX Equalizer Attributes-------------
    .RXLPM_HF_CFG                   ( 14'b00001000000000                                 ),
    .RXLPM_LF_CFG                   ( 18'b001001000000000000                             ),
    .RX_DFE_GAIN_CFG                ( 23'h0020C0                                         ),
    .RX_DFE_H2_CFG                  ( 12'b000000000000                                   ),
    .RX_DFE_H3_CFG                  ( 12'b000001000000                                   ),
    .RX_DFE_H4_CFG                  ( 11'b00011100000                                    ),
    .RX_DFE_H5_CFG                  ( 11'b00011100000                                    ),
    .RX_DFE_KL_CFG                  ( 33'b001000001000000000000001100010000              ),
    .RX_DFE_LPM_CFG                 ( 16'h0080                                           ),
    .RX_DFE_LPM_HOLD_DURING_EIDLE   ( 1'b0                                               ),
    .RX_DFE_UT_CFG                  ( 17'b00011100000000000                              ),
    .RX_DFE_VP_CFG                  ( 17'b00011101010100011                              ),
    //-----------------------Power-Down Attributes-------------------------
    .RX_CLKMUX_PD                   ( 1'b1                                               ),
    .TX_CLKMUX_PD                   ( 1'b1                                               ),
    //-----------------------FPGA RX Interface Attribute-------------------------
    .RX_INT_DATAWIDTH               ( 0                                                  ),
    //-----------------------FPGA TX Interface Attribute-------------------------
    .TX_INT_DATAWIDTH               ( 0                                                  ),
    //----------------TX Configurable Driver Attributes---------------
    .TX_QPI_STATUS_EN               ( 1'b0                                               ),
    //---------------- JTAG Attributes ---------------
    .ACJTAG_DEBUG_MODE              ( 1'b0                                               ),
    .ACJTAG_MODE                    ( 1'b0                                               ),
    .ACJTAG_RESET                   ( 1'b0                                               ),
    .ADAPT_CFG0                     ( 20'h00C10                                          ),
    .CFOK_CFG                       ( 42'h24800040E80                                    ),
    .CFOK_CFG2                      ( 6'h20                                              ),
    .CFOK_CFG3                      ( 6'h20                                              ),
    .ES_CLK_PHASE_SEL               ( 1'b0                                               ),
    .PMA_RSV5                       ( 4'h0                                               ),
    .RESET_POWERSAVE_DISABLE        ( 1'b0                                               ),
    .USE_PCS_CLK_PHASE_SEL          ( 1'b0                                               ),
    .A_RXOSCALRESET                 ( 1'b0                                               ),
    //---------------- RX Phase Interpolator Attributes---------------
    .RXPI_CFG0                      ( 2'b00                                              ),
    .RXPI_CFG1                      ( 2'b00                                              ),
    .RXPI_CFG2                      ( 2'b00                                              ),
    .RXPI_CFG3                      ( 2'b11                                              ),
    .RXPI_CFG4                      ( 1'b1                                               ),
    .RXPI_CFG5                      ( 1'b1                                               ),
    .RXPI_CFG6                      ( 3'b001                                             ),
    //------------RX Decision Feedback Equalizer(DFE)-------------
    .RX_DFELPM_CFG0                 ( 4'b0110                                            ),
    .RX_DFELPM_CFG1                 ( 1'b0                                               ),
    .RX_DFELPM_KLKH_AGC_STUP_EN     ( 1'b1                                               ),
    .RX_DFE_AGC_CFG0                ( 2'b00                                              ),
    .RX_DFE_AGC_CFG1                ( 3'b100                                             ),
    .RX_DFE_AGC_CFG2                ( 4'b0000                                            ),
    .RX_DFE_AGC_OVRDEN              ( 1'b1                                               ),
    .RX_DFE_H6_CFG                  ( 11'h020                                            ),
    .RX_DFE_H7_CFG                  ( 11'h020                                            ),
    .RX_DFE_KL_LPM_KH_CFG0          ( 2'b10                                              ),
    .RX_DFE_KL_LPM_KH_CFG1          ( 3'b010                                             ),
    .RX_DFE_KL_LPM_KH_CFG2          ( 4'b0010                                            ),
    .RX_DFE_KL_LPM_KH_OVRDEN        ( 1'b1                                               ),
    .RX_DFE_KL_LPM_KL_CFG0          ( 2'b10                                              ),
    .RX_DFE_KL_LPM_KL_CFG1          ( 3'b010                                             ),
    .RX_DFE_KL_LPM_KL_CFG2          ( 4'b0010                                            ),
    .RX_DFE_KL_LPM_KL_OVRDEN        ( 1'b1                                               ),
    .RX_DFE_ST_CFG                  ( 54'h00E100000C003F                                 ),
    //---------------- TX Phase Interpolator Attributes---------------
    .TXPI_CFG0                      ( 2'b00                                              ),
    .TXPI_CFG1                      ( 2'b00                                              ),
    .TXPI_CFG2                      ( 2'b00                                              ),
    .TXPI_CFG3                      ( 1'b0                                               ),
    .TXPI_CFG4                      ( 1'b0                                               ),
    .TXPI_CFG5                      ( 3'b100                                             ),
    .TXPI_GREY_SEL                  ( 1'b0                                               ),
    .TXPI_INVSTROBE_SEL             ( 1'b0                                               ),
    .TXPI_PPMCLK_SEL                ( "TXUSRCLK2"                                        ),
    .TXPI_PPM_CFG                   ( 8'h00                                              ),
    .TXPI_SYNFREQ_PPM               ( 3'b000                                             ),
    .TX_RXDETECT_PRECHARGE_TIME     ( 17'h155CC                                          ),
    //---------------- LOOPBACK Attributes---------------
    .LOOPBACK_CFG                   ( 1'b0                                               ),
    //----------------RX OOB Signalling Attributes---------------
    .RXOOB_CLK_CFG                  ( "PMA"                                              ),
    //---------------- CDR Attributes ---------------
    .RXOSCALRESET_TIME              ( 5'b00011                                           ),
    .RXOSCALRESET_TIMEOUT           ( 5'b00000                                           ),
    //----------------TX OOB Signalling Attributes---------------
    .TXOOB_CFG                      ( 1'b0                                               ),
    //----------------RX Buffer Attributes---------------
    .RXSYNC_MULTILANE               ( 1'b0                                               ),
    .RXSYNC_OVRD                    ( 1'b0                                               ),
    .RXSYNC_SKIP_DA                 ( 1'b0                                               ),
    //----------------TX Buffer Attributes---------------
    .TXSYNC_MULTILANE               ( TXSYNC_MULTILANE_IN                                ),
    .TXSYNC_OVRD                    ( TXSYNC_OVRD_IN                                     ),
    .TXSYNC_SKIP_DA                 ( 1'b0                                               )
) gthe2_i (
    //------------------------------- CPLL Ports -------------------------------
    .CPLLFBCLKLOST                  (                                                    ),
    .CPLLLOCK                       ( CPLLLOCK_OUT                                       ),
    .CPLLLOCKDETCLK                 ( CPLLLOCKDETCLK_IN                                  ),
    .CPLLLOCKEN                     ( 1'b1                                               ),
    .CPLLPD                         ( 1'b0                                               ),
    .CPLLREFCLKLOST                 (                                                    ),
    .CPLLREFCLKSEL                  ( 3'b001                                             ),
    .CPLLRESET                      ( CPLLRESET_IN                                       ),
    .GTRSVD                         ( 16'h0                                              ),
    .PCSRSVDIN                      ( 16'h0                                              ),
    .PCSRSVDIN2                     ( 5'h0                                               ),
    .PMARSVDIN                      ( 5'h0                                               ),
    .TSTIN                          ( 20'hfffff                                          ),
    //------------------------ Channel - Clocking Ports ------------------------
    .GTGREFCLK                      ( 1'b0                                               ),
    .GTNORTHREFCLK0                 ( 1'b0                                               ),
    .GTNORTHREFCLK1                 ( 1'b0                                               ),
    .GTREFCLK0                      ( GTREFCLK0_IN                                       ),
    .GTREFCLK1                      ( 1'b0                                               ),
    .GTSOUTHREFCLK0                 ( 1'b0                                               ),
    .GTSOUTHREFCLK1                 ( 1'b0                                               ),
    //-------------------------- Channel - DRP Ports  --------------------------
    .DRPCLK                         ( DRPCLK_IN                                          ),
    .DRPADDR                        ( 9'h011                                             ),
    .DRPDI                          ( drpdi_i                                            ),
    .DRPDO                          ( drpdo_i                                            ),
    .DRPEN                          ( drpen_i                                            ),
    .DRPRDY                         ( drprdy_i                                           ),
    .DRPWE                          ( drpwe_i                                            ),
    //----------------------------- Clocking Ports -----------------------------
    .GTREFCLKMONITOR                (                                                    ),
    .QPLLCLK                        ( qpllclk_i                                          ),
    .QPLLREFCLK                     ( qpllrefclk_i                                       ),
    .RXSYSCLKSEL                    ( 2'b00                                              ),
    .TXSYSCLKSEL                    ( 2'b00                                              ),
    //--------------- FPGA TX Interface Datapath Configuration  ----------------
    .TX8B10BEN                      ( 1'b1                                               ),
    //----------------------------- Loopback Ports -----------------------------
    .LOOPBACK                       ( 3'h0                                               ),
    //--------------------------- PCI Express Ports ----------------------------
    .PHYSTATUS                      (                                                    ),
    .RXRATE                         ( 3'h0                                               ),
    .RXVALID                        (                                                    ),
    //---------------------------- Power-Down Ports ----------------------------
    .RXPD                           ( 2'b00                                              ),
    .TXPD                           ( 2'b00                                              ),
    //------------------------ RX 8B/10B Decoder Ports -------------------------
    .SETERRSTATUS                   ( 1'b0                                               ),
    //------------------- RX Initialization and Reset Ports --------------------
    .EYESCANRESET                   ( 1'b0                                               ),
    .RXUSERRDY                      ( RXUSERRDY_IN                                       ),
    //------------------------ RX Margin Analysis Ports ------------------------
    .EYESCANDATAERROR               (                                                    ),
    .EYESCANMODE                    ( 1'b0                                               ),
    .EYESCANTRIGGER                 ( 1'b0                                               ),
    //----------------------------- Receive Ports ------------------------------
    .CLKRSVD0                       ( 1'b0                                               ),
    .CLKRSVD1                       ( 1'b0                                               ),
    .DMONFIFORESET                  ( 1'b0                                               ),
    .DMONITORCLK                    ( 1'b0                                               ),
    .RXPMARESETDONE                 ( rxpmaresetdone0                                    ),
    .RXRATEMODE                     ( 1'b0                                               ),
    .SIGVALIDCLK                    ( 1'b0                                               ),
    .TXPMARESETDONE                 (                                                    ),
    //------------ Receive Ports - 64b66b and 64b67b Gearbox Ports -------------
    .RXSTARTOFSEQ                   (                                                    ),
    //----------------------- Receive Ports - CDR Ports ------------------------
    .RXCDRFREQRESET                 ( 1'b0                                               ),
    .RXCDRHOLD                      ( 1'b0                                               ),
    .RXCDRLOCK                      (                                                    ),
    .RXCDROVRDEN                    ( 1'b0                                               ),
    .RXCDRRESET                     ( 1'b0                                               ),
    .RXCDRRESETRSV                  ( 1'b0                                               ),
    //----------------- Receive Ports - Clock Correction Ports -----------------
    .RXCLKCORCNT                    (                                                    ),
    //------------- Receive Ports - Comma Detection and Alignment --------------
    .RXSLIDE                        ( 1'b0                                               ),
    //----------------- Receive Ports - Digital Monitor Ports ------------------
    .DMONITOROUT                    (                                                    ),
    //-------- Receive Ports - FPGA RX Interface Datapath Configuration --------
    .RX8B10BEN                      ( 1'b1                                               ),
    //---------------- Receive Ports - FPGA RX Interface Ports -----------------
    .RXUSRCLK                       ( RXUSRCLK_IN                                        ),
    .RXUSRCLK2                      ( RXUSRCLK_IN                                        ),
    //---------------- Receive Ports - FPGA RX interface Ports -----------------
    .RXDATA                         ( {rxdata_float_i, RXDATA_OUT}                       ),
    //----------------- Receive Ports - Pattern Checker Ports ------------------
    .RXPRBSERR                      (                                                    ),
    .RXPRBSSEL                      ( 3'h0                                               ),
    //----------------- Receive Ports - Pattern Checker ports ------------------
    .RXPRBSCNTRESET                 ( 1'b0                                               ),
    //---------------- Receive Ports - RX 8B/10B Decoder Ports -----------------
    .RXDISPERR                      (                                                    ),
    .RXNOTINTABLE                   (                                                    ),
    //---------------------- Receive Ports - RX AFE Ports ----------------------
    .GTHRXN                         ( RXN_IN                                             ),
    .GTHRXP                         ( RXP_IN                                             ),
    //----------------- Receive Ports - RX Buffer Bypass Ports -----------------
    .RXBUFRESET                     ( 1'b0                                               ),
    .RXBUFSTATUS                    (                                                    ),
    .RXDDIEN                        ( 1'b0                                               ),
    .RXDLYBYPASS                    ( 1'b1                                               ),
    .RXDLYEN                        ( 1'b0                                               ),
    .RXDLYOVRDEN                    ( 1'b0                                               ),
    .RXDLYSRESET                    ( 1'b0                                               ),
    .RXDLYSRESETDONE                (                                                    ),
    .RXPHALIGN                      ( 1'b0                                               ),
    .RXPHALIGNDONE                  (                                                    ),
    .RXPHALIGNEN                    ( 1'b0                                               ),
    .RXPHDLYPD                      ( 1'b0                                               ),
    .RXPHDLYRESET                   ( 1'b0                                               ),
    .RXPHMONITOR                    (                                                    ),
    .RXPHOVRDEN                     ( 1'b0                                               ),
    .RXPHSLIPMONITOR                (                                                    ),
    .RXSTATUS                       (                                                    ),
    .RXSYNCALLIN                    ( 1'b0                                               ),
    .RXSYNCDONE                     (                                                    ),
    .RXSYNCIN                       ( 1'b0                                               ),
    .RXSYNCMODE                     ( 1'b0                                               ),
    .RXSYNCOUT                      (                                                    ),
    //------------ Receive Ports - RX Byte and Word Alignment Ports ------------
    .RXBYTEISALIGNED                ( RXBYTEISALIGNED_OUT                                ),
    .RXBYTEREALIGN                  (                                                    ),
    .RXCOMMADET                     (                                                    ),
    .RXCOMMADETEN                   ( 1'b1                                               ),
    .RXMCOMMAALIGNEN                ( 1'b1                                               ),
    .RXPCOMMAALIGNEN                ( 1'b1                                               ),
    //---------------- Receive Ports - RX Channel Bonding Ports ----------------
    .RXCHANBONDSEQ                  (                                                    ),
    .RXCHBONDEN                     ( 1'b0                                               ),
    .RXCHBONDLEVEL                  ( 3'h0                                               ),
    .RXCHBONDMASTER                 ( 1'b0                                               ),
    .RXCHBONDO                      (                                                    ),
    .RXCHBONDSLAVE                  ( 1'b0                                               ),
    //--------------- Receive Ports - RX Channel Bonding Ports  ----------------
    .RXCHANISALIGNED                (                                                    ),
    .RXCHANREALIGN                  (                                                    ),
    //---------- Receive Ports - RX Decision Feedback Equalizer(DFE) -----------
    .RSOSINTDONE                    (                                                    ),
    .RXDFESLIDETAPOVRDEN            ( 1'b0                                               ),
    .RXOSCALRESET                   ( 1'b0                                               ),
    //------------------ Receive Ports - RX Equailizer Ports -------------------
    .RXLPMHFHOLD                    ( 1'b0                                               ),
    .RXLPMHFOVRDEN                  ( 1'b0                                               ),
    .RXLPMLFHOLD                    ( 1'b0                                               ),
    //------------------- Receive Ports - RX Equalizar Ports -------------------
    .RXDFESLIDETAPSTARTED           (                                                    ),
    .RXDFESLIDETAPSTROBEDONE        (                                                    ),
    .RXDFESLIDETAPSTROBESTARTED     (                                                    ),
    //------------------- Receive Ports - RX Equalizer Ports -------------------
    .RXADAPTSELTEST                 ( 14'h0                                              ),
    .RXDFEAGCHOLD                   ( 1'b0                                               ),
    .RXDFEAGCOVRDEN                 ( 1'b0                                               ),
    .RXDFEAGCTRL                    ( 5'b10000                                           ), //(5'b01000),
    .RXDFECM1EN                     ( 1'b0                                               ),
    .RXDFELFHOLD                    ( 1'b0                                               ),
    .RXDFELFOVRDEN                  ( 1'b0                                               ),
    .RXDFELPMRESET                  ( 1'b0                                               ),
    .RXDFESLIDETAP                  ( 5'h0                                               ),
    .RXDFESLIDETAPADAPTEN           ( 1'b0                                               ),
    .RXDFESLIDETAPHOLD              ( 1'b0                                               ),
    .RXDFESLIDETAPID                ( 6'h0                                               ),
    .RXDFESLIDETAPINITOVRDEN        ( 1'b0                                               ),
    .RXDFESLIDETAPONLYADAPTEN       ( 1'b0                                               ),
    .RXDFESLIDETAPSTROBE            ( 1'b0                                               ),
    .RXDFESTADAPTDONE               (                                                    ),
    .RXDFETAP2HOLD                  ( 1'b0                                               ),
    .RXDFETAP2OVRDEN                ( 1'b0                                               ),
    .RXDFETAP3HOLD                  ( 1'b0                                               ),
    .RXDFETAP3OVRDEN                ( 1'b0                                               ),
    .RXDFETAP4HOLD                  ( 1'b0                                               ),
    .RXDFETAP4OVRDEN                ( 1'b0                                               ),
    .RXDFETAP5HOLD                  ( 1'b0                                               ),
    .RXDFETAP5OVRDEN                ( 1'b0                                               ),
    .RXDFETAP6HOLD                  ( 1'b0                                               ),
    .RXDFETAP6OVRDEN                ( 1'b0                                               ),
    .RXDFETAP7HOLD                  ( 1'b0                                               ),
    .RXDFETAP7OVRDEN                ( 1'b0                                               ),
    .RXDFEUTHOLD                    ( 1'b0                                               ),
    .RXDFEUTOVRDEN                  ( 1'b0                                               ),
    .RXDFEVPHOLD                    ( 1'b0                                               ),
    .RXDFEVPOVRDEN                  ( 1'b0                                               ),
    .RXDFEVSEN                      ( 1'b0                                               ),
    .RXDFEXYDEN                     ( 1'b1                                               ),
    .RXLPMLFKLOVRDEN                ( 1'b0                                               ),
    .RXMONITOROUT                   (                                                    ),
    .RXMONITORSEL                   ( 2'b00                                              ),
    .RXOSHOLD                       ( 1'b0                                               ),
    .RXOSINTCFG                     ( 4'b0110                                            ),
    .RXOSINTEN                      ( 1'b1                                               ),
    .RXOSINTHOLD                    ( 1'b0                                               ),
    .RXOSINTID0                     ( 4'h0                                               ),
    .RXOSINTNTRLEN                  ( 1'b0                                               ),
    .RXOSINTOVRDEN                  ( 1'b0                                               ),
    .RXOSINTSTARTED                 (                                                    ),
    .RXOSINTSTROBE                  ( 1'b0                                               ),
    .RXOSINTSTROBEDONE              (                                                    ),
    .RXOSINTSTROBESTARTED           (                                                    ),
    .RXOSINTTESTOVRDEN              ( 1'b0                                               ),
    .RXOSOVRDEN                     ( 1'b0                                               ),
    //---------- Receive Ports - RX Fabric ClocK Output Control Ports ----------
    .RXRATEDONE                     (                                                    ),
    //------------- Receive Ports - RX Fabric Output Control Ports -------------
    .RXOUTCLK                       ( RXOUTCLK_OUT                                       ),
    .RXOUTCLKFABRIC                 (                                                    ),
    .RXOUTCLKPCS                    (                                                    ),
    .RXOUTCLKSEL                    ( 3'b010                                             ),
    //-------------------- Receive Ports - RX Gearbox Ports --------------------
    .RXDATAVALID                    (                                                    ),
    .RXHEADER                       (                                                    ),
    .RXHEADERVALID                  (                                                    ),
    //------------------- Receive Ports - RX Gearbox Ports  --------------------
    .RXGEARBOXSLIP                  ( 1'b0                                               ),
    //----------- Receive Ports - RX Initialization and Reset Ports ------------
    .GTRXRESET                      ( gtrxreset_o                                        ),
    .RXOOBRESET                     ( 1'b0                                               ),
    .RXPCSRESET                     ( 1'b0                                               ),
    .RXPMARESET                     ( 1'b0                                               ),
    //---------------- Receive Ports - RX Margin Analysis ports ----------------
    .RXLPMEN                        ( 1'b0                                               ),
    //----------------- Receive Ports - RX OOB Signaling ports -----------------
    .RXCOMSASDET                    ( RXCOMSASDET_OUT                                    ),
    .RXCOMINITDET                   ( RXCOMINITDET_OUT                                   ),
    .RXCOMWAKEDET                   ( RXCOMWAKEDET_OUT                                   ),
    .RXELECIDLE                     ( RXELECIDLE_OUT                                     ),
    .RXELECIDLEMODE                 ( 2'b00                                              ),
    //--------------- Receive Ports - RX Polarity Control Ports ----------------
    .RXPOLARITY                     ( 1'b0                                               ),
    //----------------- Receive Ports - RX8B/10B Decoder Ports -----------------
    .RXCHARISCOMMA                  (                                                    ),
    .RXCHARISK                      ( {rxcharisk_float_i, RXCHARISK_OUT}                 ),
    //---------------- Receive Ports - Rx Channel Bonding Ports ----------------
    .RXCHBONDI                      ( 5'b00000                                           ),
    //------------ Receive Ports -RX Initialization and Reset Ports ------------
    .RXRESETDONE                    (                                                    ),
    //------------------------------ Rx AFE Ports ------------------------------
    .RXQPIEN                        ( 1'b0                                               ),
    .RXQPISENN                      (                                                    ),
    .RXQPISENP                      (                                                    ),
    //------------------------- TX Buffer Bypass Ports -------------------------
    .TXPHDLYTSTCLK                  ( 1'b0                                               ),
    //---------------------- TX Configurable Driver Ports ----------------------
    .TXPOSTCURSOR                   ( 5'b00000                                           ),
    .TXPOSTCURSORINV                ( 1'b0                                               ),
    .TXPRECURSOR                    ( 5'h0                                               ),
    .TXPRECURSORINV                 ( 1'b0                                               ),
    .TXQPIBIASEN                    ( 1'b0                                               ),
    .TXQPISTRONGPDOWN               ( 1'b0                                               ),
    .TXQPIWEAKPUP                   ( 1'b0                                               ),
    //------------------- TX Initialization and Reset Ports --------------------
    .CFGRESET                       ( 1'b0                                               ),
    .GTTXRESET                      ( GTTXRESET_IN                                       ),
    .PCSRSVDOUT                     (                                                    ),
    .TXUSERRDY                      ( TXUSERRDY_IN                                       ),
    //--------------- TX Phase Interpolator PPM Controller Ports ---------------
    .TXPIPPMEN                      ( 1'b0                                               ),
    .TXPIPPMOVRDEN                  ( 1'b0                                               ),
    .TXPIPPMPD                      ( 1'b0                                               ),
    .TXPIPPMSEL                     ( 1'b0                                               ),
    .TXPIPPMSTEPSIZE                ( 5'h0                                               ),
    //-------------------- Transceiver Reset Mode Operation --------------------
    .GTRESETSEL                     ( 1'b0                                               ),
    .RESETOVRD                      ( 1'b0                                               ),
    //----------------------------- Transmit Ports -----------------------------
    .TXRATEMODE                     ( 1'b0                                               ),
    //------------ Transmit Ports - 64b66b and 64b67b Gearbox Ports ------------
    .TXHEADER                       ( 3'h0                                               ),
    //-------------- Transmit Ports - 8b10b Encoder Control Ports --------------
    .TXCHARDISPMODE                 ( 8'h0                                               ),
    .TXCHARDISPVAL                  ( 8'h0                                               ),
    //---------------- Transmit Ports - FPGA TX Interface Ports ----------------
    .TXUSRCLK                       ( TXUSRCLK_IN                                        ),
    .TXUSRCLK2                      ( TXUSRCLK_IN                                        ),
    //------------------- Transmit Ports - PCI Express Ports -------------------
    .TXELECIDLE                     ( TXELECIDLE_IN                                      ),
    .TXMARGIN                       ( 3'h0                                               ),
    .TXRATE                         ( 3'h0                                               ),
    .TXSWING                        ( 1'b0                                               ),
    //---------------- Transmit Ports - Pattern Generator Ports ----------------
    .TXPRBSFORCEERR                 ( 1'b0                                               ),
    //---------------- Transmit Ports - TX Buffer Bypass Ports -----------------
    .TXDLYBYPASS                    ( 1'b1                                               ),
    .TXDLYEN                        ( 1'b0                                               ),
    .TXDLYHOLD                      ( 1'b0                                               ),
    .TXDLYOVRDEN                    ( 1'b0                                               ),
    .TXDLYSRESET                    ( 1'b0                                               ),
    .TXDLYSRESETDONE                (                                                    ),
    .TXDLYUPDOWN                    ( 1'b0                                               ),
    .TXPHALIGN                      ( 1'b0                                               ),
    .TXPHALIGNDONE                  (                                                    ),
    .TXPHALIGNEN                    ( 1'b0                                               ),
    .TXPHDLYPD                      ( 1'b0                                               ),
    .TXPHDLYRESET                   ( 1'b0                                               ),
    .TXPHINIT                       ( 1'b0                                               ),
    .TXPHINITDONE                   (                                                    ),
    .TXPHOVRDEN                     ( 1'b0                                               ),
    .TXSYNCALLIN                    ( 1'b0                                               ),
    .TXSYNCDONE                     (                                                    ),
    .TXSYNCIN                       ( 1'b0                                               ),
    .TXSYNCMODE                     ( 1'b0                                               ),
    .TXSYNCOUT                      (                                                    ),
    //-------------------- Transmit Ports - TX Buffer Ports --------------------
    .TXBUFSTATUS                    (                                                    ),
    //------------- Transmit Ports - TX Configurable Driver Ports --------------
    .TXBUFDIFFCTRL                  ( 3'b100                                             ),
    .TXDEEMPH                       ( 1'b0                                               ),
    .TXDIFFCTRL                     ( 4'b1000                                            ),
    .TXDIFFPD                       ( 1'b0                                               ),
    .TXINHIBIT                      ( 1'b0                                               ),
    .TXMAINCURSOR                   ( 7'b0000000                                         ),
    .TXPISOPD                       ( 1'b0                                               ),
    //---------------- Transmit Ports - TX Data Path interface -----------------
    .TXDATA                         ( {48'h0, TXDATA_IN}                                 ),
    //-------------- Transmit Ports - TX Driver and OOB signaling --------------
    .GTHTXN                         ( TXN_OUT                                            ),
    .GTHTXP                         ( TXP_OUT                                            ),
    //--------- Transmit Ports - TX Fabric Clock Output Control Ports ----------
    .TXOUTCLK                       ( TXOUTCLK_OUT                                       ),
    .TXOUTCLKFABRIC                 (                                                    ),
    .TXOUTCLKPCS                    (                                                    ),
    .TXOUTCLKSEL                    ( 3'b010                                             ),
    .TXRATEDONE                     (                                                    ),
    //------------------- Transmit Ports - TX Gearbox Ports --------------------
    .TXGEARBOXREADY                 (                                                    ),
    .TXSEQUENCE                     ( 7'h0                                               ),
    .TXSTARTSEQ                     ( 1'b0                                               ),
    //----------- Transmit Ports - TX Initialization and Reset Ports -----------
    .TXPCSRESET                     ( 1'b0                                               ),
    .TXPMARESET                     ( 1'b0                                               ),
    .TXRESETDONE                    (                                                    ),
    //---------------- Transmit Ports - TX OOB signalling Ports ----------------
    .TXCOMFINISH                    (                                                    ),
    .TXCOMINIT                      ( TXCOMINIT_IN                                       ),
    .TXCOMSAS                       ( TXCOMSAS_IN                                        ),
    .TXCOMWAKE                      ( TXCOMWAKE_IN                                       ),
    .TXPDELECIDLEMODE               ( 1'b0                                               ),
    //--------------- Transmit Ports - TX Polarity Control Ports ---------------
    .TXPOLARITY                     ( 1'b0                                               ),
    //------------- Transmit Ports - TX Receiver Detection Ports  --------------
    .TXDETECTRX                     ( 1'b0                                               ),
    //---------------- Transmit Ports - TX8b/10b Encoder Ports -----------------
    .TX8B10BBYPASS                  ( 8'h0                                               ),
    //---------------- Transmit Ports - pattern Generator Ports ----------------
    .TXPRBSSEL                      ( 3'h0                                               ),
    //--------- Transmit Transmit Ports - 8b10b Encoder Control Ports ----------
    .TXCHARISK                      ( {7'h0, TXCHARISK_IN}                               ),
    //--------------------- Tx Configurable Driver  Ports ----------------------
    .TXQPISENN                      (                                                    ),
    .TXQPISENP                      (                                                    )
);


endmodule
