
//--------------------------------------------------------------------------------------------------------
// Module  : uart_rx
// Type    : synthesizable, IP's top
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: convert UART (as ASCII-HEX format) to AXI stream
//--------------------------------------------------------------------------------------------------------

module uart_rx #(
    parameter CLK_DIV = 434,      // UART baud rate = clk freq/CLK_DIV. for example, when clk=50MHz, CLK_DIV=434, then baud=50MHz/434=115200
    parameter PARITY  = "NONE",   // "NONE", "ODD" or "EVEN"
    parameter ASIZE   = 10        // UART RX buffer size = 2^ASIZE, Set it smaller if your FPGA doesn't have enough BRAM
) (
    input  wire        rstn,
    input  wire        clk,
    // uart rx input signal
    input  wire        i_uart_rx,
    // user interface
    input  wire        o_tready,
    output reg         o_tvalid,
    output wire        o_tlast,
    output wire [31:0] o_tdata
);


reg  [7:0] rx_data = '0;
reg        rx_en = 1'b0;


reg        rxbuff = 1'b1;

always @ (posedge clk or negedge rstn)
    if(~rstn)
        rxbuff <= 1'b1;
    else
        rxbuff <= i_uart_rx;




reg [31:0] cyc = 0;
reg        cycend = 1'b0;
reg [ 5:0] rxshift = '0;

wire rbit = rxshift[2] & rxshift[1] | rxshift[1] & rxshift[0] | rxshift[2] & rxshift[0] ;

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        cyc <= 0;
        cycend <= 1'b0;
        rxshift <= '0;
    end else begin
        cyc <= (cyc+1<CLK_DIV) ? cyc + 1 : 0;
        cycend <= 1'b0;
        if( cyc == (CLK_DIV/4)*0 || cyc == (CLK_DIV/4)*1 || cyc == (CLK_DIV/4)*2 || cyc == (CLK_DIV/4)*3 ) begin
            cycend <= 1'b1;
            rxshift <= {rxshift[4:0], rxbuff};
        end
    end




reg [4:0] cnt = '0;
enum logic [2:0] {S_IDLE, S_DATA, S_PARI, S_OKAY, S_FAIL} stat = S_IDLE;

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        {rx_data, rx_en} <= '0;
        cnt  <= '0;
        stat <= S_IDLE;
    end else begin
        rx_en <= 1'b0;
        if( cycend ) begin
            case(stat)
                S_IDLE: begin
                    cnt <= '0;
                    if(rxshift == 6'b111_000) stat <= S_DATA;
                end
                S_DATA: begin
                    cnt <= cnt + 5'd1;
                    if(cnt[1:0] == '1) rx_data <= {rbit, rx_data[7:1]};
                    if(cnt      == '1) stat <= (PARITY=="NONE") ? S_OKAY : S_PARI;
                end
                S_PARI: begin
                    cnt <= cnt + 5'd1;
                    if(cnt[1:0] == '1) stat <=((PARITY=="EVEN") ^ rbit ^ (^rx_data)) ? S_OKAY : S_FAIL;
                end
                S_OKAY: begin
                    cnt <= cnt + 5'd1;
                    if(cnt[1:0] == '1) begin
                        rx_en <= rbit;
                        stat <= rbit ? S_IDLE : S_FAIL;
                    end
                end
                S_FAIL: if(rxshift[2:0] == '1) stat <= S_IDLE;
            endcase
        end
    end



function automatic logic isnewline(input [7:0] c);
    return c==8'h0D || c==8'h0A;                // '\r' '\n'
endfunction

function automatic logic isspace(input [7:0] c);
    return c==8'h20 || c==8'h09 || c==8'h0B;    // ' ' '\t' '\v'
endfunction

function automatic logic [3:0] ishex(input [7:0] c);
    if(c>=8'h30 && c<= 8'h39)                               // '0'~'9'
        return 1'b1;
    else if(c>=8'h41 && c<=8'h46 || c>=8'h61 && c<=8'h66)   // 'A'~'F' , 'a'~'f'
        return 1'b1;
    else
        return 1'b0;
endfunction

function automatic logic [3:0] ascii2hex(input [7:0] c);
    if(c>=8'h30 && c<= 8'h39)                               // '0'~'9'
        return c[3:0];
    else if(c>=8'h41 && c<=8'h46 || c>=8'h61 && c<=8'h66)   // 'A'~'F' , 'a'~'f'
        return c[3:0] + 8'h9;
    else
        return 4'd0;
endfunction


reg        data1_valid = 1'b1;
reg [ 2:0] data1_cnt = '0;
wire[ 2:0] data1_wcnt = {data1_cnt[2:1], ~data1_cnt[0]};
reg        data1_en = '0;
reg        data1_end = '0;
reg [31:0] data1 = '0;

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        data1_valid <= 1'b1;
        data1_cnt <= '0;
        data1_en <= '0;
        data1_end <= '0;
        data1 <= '0;
    end else begin
        data1_en <= 1'b0;
        data1_end <= '0;
        if(rx_en) begin
            if (ishex(rx_data)) begin
                data1_cnt <= data1_cnt + 3'd1;
                data1_en <= (data1_cnt == '1) && data1_valid;
                data1[data1_wcnt*4 +: 4] <= ascii2hex(rx_data);
            end else if(isnewline(rx_data)) begin
                data1_valid <= 1'b1;
                data1_cnt <= '0;
                data1_end <= 1'b1;
            end else if(!isspace(rx_data)) begin
                data1_valid <= 1'b0;
            end
        end
    end


reg        data2_save_en = '0;
reg [31:0] data2_save = '0;
reg        tvalid = '0;
reg        tlast = '0;
reg [31:0] tdata = '0;

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        data2_save_en <= '0;
        data2_save <= '0;
        {tvalid, tlast, tdata} <= '0;
    end else begin
        {tvalid, tlast} <= '0;
        if(data1_en) begin
            data2_save_en <= 1'b1;
            data2_save <= data1;
            tvalid <= data2_save_en;
            tdata <= data2_save;
        end else if(data1_end) begin
            data2_save_en <= 1'b0;
            tvalid <= data2_save_en;
            tlast <= data2_save_en;
            tdata <= data2_save;
        end
    end




localparam DSIZE = 33;

reg  [DSIZE-1:0] buffer [1<<ASIZE];  // may automatically synthesize to BRAM

logic [ASIZE:0] wptr, rptr;

wire full  = wptr == {~rptr[ASIZE], rptr[ASIZE-1:0]};
wire empty = wptr == rptr;

//assign itready = ~full;

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        wptr <= '0;
    end else begin
        if(tvalid & ~full)
            wptr <= wptr + (1+ASIZE)'(1);
    end

always @ (posedge clk)
    if(tvalid & ~full)
        buffer[wptr[ASIZE-1:0]] <= {tlast, tdata};

wire            rdready = ~o_tvalid | o_tready;
reg             rdack;
reg [DSIZE-1:0] rddata;
reg [DSIZE-1:0] keepdata;
assign {o_tlast, o_tdata} = rdack ? rddata : keepdata;

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        o_tvalid <= 1'b0;
        rdack <= 1'b0;
        rptr <= '0;
        keepdata <= '0;
    end else begin
        o_tvalid <= ~empty | ~rdready;
        rdack <= ~empty & rdready;
        if(~empty & rdready)
            rptr <= rptr + (1+ASIZE)'(1);
        if(rdack)
            keepdata <= rddata;
    end

always @ (posedge clk)
    rddata <= buffer[rptr[ASIZE-1:0]];

endmodule
