module cache(
    clk,
    proc_reset,
    proc_read,
    proc_write,
    proc_addr,
    proc_rdata,
    proc_wdata,
    proc_stall,
    mem_read,
    mem_write,
    mem_addr,
    mem_rdata,
    mem_wdata,
    mem_ready
);
    
//==== input/output definition ============================
    input          clk;
    // processor interface
    input          proc_reset;
    input          proc_read, proc_write;
    input   [29:0] proc_addr;
    input   [31:0] proc_wdata;
    output         proc_stall;
    output  [31:0] proc_rdata;
    // memory interface
    input  [127:0] mem_rdata;
    input          mem_ready;
    output         mem_read, mem_write;
    output  [27:0] mem_addr;
    output [127:0] mem_wdata;

//==== parameter definition ===============================
parameter WAYS = 2;    
parameter BLOCK_WIDTH = 128,
genvar gen_i;
//==== wire/reg definition ================================
reg                     wen_sets    [0:WAYS-1]; // write enable signal for each set
reg                     update_sets [0:WAYS-1]; // updated valid signal
reg                     valid_next; // updated valid bit
reg                     dirty_next; // updated dirty bit
reg                     input_src; // input source, 0: CPU, 1: memory
reg  [BLOCK_WIDTH-1:0]  wdata;      // data written to cache line
//==== combinational circuit ==============================

//==== sequential circuit =================================


generate
    for (gen_i = 0; gen_i < WAYS; gen_i = gen_i + 1)begin
        set u0(
            .clk(clk),
            .rst(proc_reset),
            .write_i(),
            .update_i(),
            .valid_i(),
            .dirty_i(),
            .input_src_i(0),
            .wdata_i(),
            .addr_i(),
            .hit_o(),
            .rdata_o()
        );
    end

endgenerate

endmodule

module set #(
    parameter LINE_NUM = 8,
    parameter TAG_WIDTH = 25,
    parameter BLOCK_WIDTH = 128,
    parameter WORD_WIDTH = 32
)(
    input clk,
    input rst,
    input write_i,
    input update_i,
    input valid_i,
    input dirty_i,
    input input_src_i, // input_src_i = 0: CPU, 1: memory
    input [BLOCK_WIDTH-1:0] wdata_i,
    input [29:0] addr_i;
    output        hit_o, 
    output [31:0] rdata_o
);

/* data read from cache line */
wire                      valid_lines [0:LINE_NUM-1];
wire                      dirty_lines [0:LINE_NUM-1];
wire    [TAG_WIDTH-1:0]   tag_lines   [0:LINE_NUM-1];
wire    [BLOCK_WIDTH-1:0] rdata_lines [0:LINE_NUM-1];

/* information from input addr */
wire    [24:0]            tag_i;
wire    [2:0]             index_i;
wire    [1:0]             offset_i;

/* generate signal */
wire                      valid;
wire                      dirty;
wire                      hit;
wire    [BLOCK_WIDTH-1:0] rdata;
wire    [1:0]             offset;

/* control signal for cache lines */
reg                       wen_lines    [0:LINE_NUM-1]; // write enable signal for each line
reg                       valid_next; // updated valid signal
reg                       dirty_next; // updated dirty signal
reg                       wdata;      // data written to cache line, the source could by CPU or memory

genvar gen_i;
integer i;
assign {tag_i, index_i, offset_i} = addr_i;

assign valid = valid_lines[index_i];
assign dirty = dirty_lines[index_i];
assign rdata  = rdata_lines[index_i];
assign hit  = (valid && (tag_i == tag_lines[index_i]));

/* output assignment */
assign hit_o = hit;
assign rdata_o = rdata[offset_i * WORD_WIDTH +: WORD_WIDTH];

/* instantiate cache lines */
generate
    for (gen_i = 0; gen_i < LINE_NUM; gen_i = gen_i + 1) begin
        line l(
            .clk(clk),
            .rst(rst),
            .write_i(wen_lines[gen_i]),
            .valid_i(valid_next),
            .dirty_i(dirty_next),
            .wdata_i(wdata),
            .valid_o(valid_lines[gen_i]),
            .dirty_o(dirty_lines[gen_i]),
            .tag_o(tag_lines[gen_i]),
            .rdata_o(rdata_lines[gen_i])
        );
    end
endgenerate

/* prepare wdata for cache line */
always @(*) begin
    for (i = 0; i < LINE_NUM; i = i + 1) begin
        wen_lines[i] = (write_i || update_i)&& (index_i == i);
    end
    if (write_i) begin
        if (input_src_i) begin
            /* input is from data memory, write 128 bit at once */
            wdata = wdata_i;
        end else begin
            /* input is from CPU, we only write 32 bit data according to offset */
            case(offset_i)
                2'b00: wdata = {rdata[127:32], wdata_i[31:0]};
                2'b01: wdata = {rdata[127:64], wdata_i[31:0], rdata[31:0]};
                2'b10: wdata = {rdata[127:95], wdata_i[31:0], rdata[63:0]};
                2'b11: wdata = {wdata_i, rdata[95:0]};
            endcase
        end
    end else begin
        wdata = rdata;
    end
end

/* update attributes of cache lines */
assign valid_next = (update_i) ? valid_i : valid;
assign dirty_next = (update_i) ? dirty_i : dirty;

endmodule

module line #(
    parameter TAG_WIDTH = 25,
    parameter BLOCK_WIDTH = 128,
    parameter WORD_WIDTH = 32
)(
    input clk,
    input rst,
    input write_i,
    input valid_i,
    input dirty_i,
    input [BLOCK_WIDTH-1:0] wdata_i,
    output valid_o,
    output dirty_o,
    output [24:0] tag_o,
    output [WORD_WIDTH-1:0] rdata_o
);

integer i;
reg         valid_r, valid_w;
reg         dirty_r, dirty_w;
reg [TAG_WIDTH-1:0] tag_r, tag_w;
reg [BLOCK_WIDTH-1:0]  data_r, data_w;

/* output logic */
assign valid_o = valid_r;
assign dirty_o = dirty_r;
assign tag_o = tag_r;
assign data_o = data_r[offset_i];

always @(*) begin:update_logic
    if (write_i) begin
        valid_w = valid_i;
        dirty_w = dirty_i;
        tag_w = tag_i;
        data_w = wdata_i;
    end else begin
        valid_w = valid_r;
        dirty_w = dirty_r;
        tag_w = tag_r;
        data_w = data_r;
    end
end

always @(posedge clk) begin
    if (rst) begin
        valid_r <= 0;
        dirty_r <= 0;
        tag_r <= 0;
        data_r[i] <= 0;
    end else begin
        valid_r <= valid_w;
        dirty_r <= dirty_w;
        tag_r <= tag_w;
        data_r[i] <= data_w[i];
    end
end
endmodule