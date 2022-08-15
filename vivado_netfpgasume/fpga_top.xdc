
#System Clock signal (200 MHz)
set_property -dict { PACKAGE_PIN H19   IOSTANDARD LVDS     } [get_ports { FPGA_SYSCLK_P }];
set_property -dict { PACKAGE_PIN G18   IOSTANDARD LVDS     } [get_ports { FPGA_SYSCLK_N }];
create_clock -add -name sys_clk_pin -period 5.00 -waveform {0 2.5} [get_ports {FPGA_SYSCLK_P}];


#BTN
set_property -dict { PACKAGE_PIN AR13  IOSTANDARD LVCMOS15 } [get_ports { BTN0 }];


#LED
set_property -dict { PACKAGE_PIN AR22  IOSTANDARD LVCMOS15 } [get_ports { LED[0] }];
set_property -dict { PACKAGE_PIN AR23  IOSTANDARD LVCMOS15 } [get_ports { LED[1] }];


#UART
set_property -dict { PACKAGE_PIN BA19  IOSTANDARD LVCMOS15 } [get_ports { UART_TX }];
set_property -dict { PACKAGE_PIN AY19  IOSTANDARD LVCMOS15 } [get_ports { UART_RX }];


#SATA Transceiver clock (150 MHz). Note: This clock is attached to a MGTREFCLK pin
set_property -dict { PACKAGE_PIN T8 } [get_ports { SATA_CLK_P }];
set_property -dict { PACKAGE_PIN T7 } [get_ports { SATA_CLK_N }];
create_clock -add -name sata_clk_pin -period 6.666 -waveform {0 3.333 } [get_ports {SATA_CLK_P}];


#SATA Transceivers
set_property -dict { PACKAGE_PIN W6 } [get_ports { SATA0_B_P }];
set_property -dict { PACKAGE_PIN W5 } [get_ports { SATA0_B_N }];
set_property -dict { PACKAGE_PIN U2 } [get_ports { SATA0_A_P }];
set_property -dict { PACKAGE_PIN U1 } [get_ports { SATA0_A_N }];
#set_property -dict { PACKAGE_PIN V4 } [get_ports { SATA1_B_P }];
#set_property -dict { PACKAGE_PIN V3 } [get_ports { SATA1_B_N }];
#set_property -dict { PACKAGE_PIN T4 } [get_ports { SATA1_A_P }];
#set_property -dict { PACKAGE_PIN T3 } [get_ports { SATA1_A_N }];
