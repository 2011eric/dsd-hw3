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
parameter BLOCK_WIDTH = 128;
parameter TAG_WIDTH = 26;
parameter WORD_WIDTH = 32;
parameter LINE_NUM = 4;
localparam S_IDLE = 0, S_WB = 1, S_FETCH = 2;

genvar gen_i;
integer i;
//==== wire/reg definition ================================
reg                     wen_sets    [0:WAYS-1]; // write enable signal for each set
reg                     update_sets [0:WAYS-1]; // updated valid signal
wire                    valid_sets    [0:WAYS-1];
wire                    hit_sets    [0:WAYS-1];
wire                    dirty_sets    [0:WAYS-1];
wire [TAG_WIDTH-1:0]    tag_sets    [0:WAYS-1];
wire [BLOCK_WIDTH-1:0]  rdata_sets  [0:WAYS-1]; // 128 bit 
reg                     valid_next; // updated valid bit
reg                     dirty_next; // updated dirty bit
wire                    input_src; // input source, 0: CPU, 1: memory
reg  [BLOCK_WIDTH-1:0]  wdata;      // data written to cache line
reg  [BLOCK_WIDTH-1:0]  rdata;      

wire [1:0]              index_i;
wire [1:0]              offset_i;

reg  [1:0]              state_r, state_w;
reg                     lru_lines_r [0:LINE_NUM-1], lru_lines_w   [0:LINE_NUM-1];      
reg                    replace_sel;
wire [WAYS-1:0]         hit_tmp;
wire                    hit; // hit are ORed result from all the hit signal in each way
wire                    dirty;
reg                     stall;
reg                     wen; // wen for cache set
reg                     update;
generate
    for (gen_i = 0; gen_i < WAYS; gen_i = gen_i + 1)begin:gen_blk1
        set u0(
            .clk(clk),
            .rst(proc_reset),
            .write_i(wen_sets[gen_i]),
            .update_i(update_sets[gen_i]),
            .valid_i(valid_next),
            .dirty_i(dirty_next),
            .input_src_i(input_src),
            .wdata_i(wdata),
            .addr_i(proc_addr),
            .dirty_o(dirty_sets[gen_i]),
            .valid_o(valid_sets[gen_i]),
            .hit_o(hit_sets[gen_i]),
            .tag_o(tag_sets[gen_i]),
            .rdata_o(rdata_sets[gen_i])
        );
        assign hit_tmp[gen_i] = hit_sets[gen_i];
    end
endgenerate
//==== combinational circuit ==============================
assign hit = |hit_tmp;
assign index_i = proc_addr[3:2];
assign offset_i = proc_addr[1:0];
assign dirty = dirty_sets[replace_sel];
assign input_src = (state_r == S_FETCH);

/* memory control signal */
assign mem_read = (state_r == S_FETCH);
assign mem_write = (state_r == S_WB);
assign mem_addr = (state_r == S_WB) ? {tag_sets[replace_sel], index_i} : proc_addr[29:2];
assign mem_wdata = (state_r == S_WB) ? rdata_sets[replace_sel] : 0;

assign proc_stall = !(state_r == S_IDLE && hit);
assign proc_rdata = rdata[WORD_WIDTH*offset_i +: WORD_WIDTH];
always @(*) begin:state_logic
    state_w = state_r;
    update = 0;
    valid_next = 0;
    dirty_next = 0;
    wen = 0;
    wdata = 0;
    for (i = 0; i < LINE_NUM; i = i + 1)
        lru_lines_w[i] = lru_lines_r[i];
    case (state_r)
        S_IDLE: begin
            if (proc_read || proc_write) begin
                if (!hit) begin
                    if (dirty) 
                        state_w = S_WB;
                    else
                        state_w = S_FETCH;
                end else begin
                    lru_lines_w[index_i] = ~replace_sel;
                    if (proc_write) begin
                        wen = 1;
                        update = 1;
                        valid_next = 1;
                        dirty_next = 1;
                        wdata = proc_wdata;
                    end
                    state_w = S_IDLE;
                end
            end else begin
                state_w = S_IDLE;
            end
        end
        S_WB: begin
            if (mem_ready) begin
                state_w = S_FETCH;
            end else begin
                state_w = S_WB;
            end
        end
        S_FETCH: begin
            if (mem_ready) begin
                lru_lines_w[index_i] = ~replace_sel;
                state_w = S_IDLE;
                wen = 1;
                update = 1;
                valid_next = 1;
                if (proc_write) begin // here we fetch from memory and perform write operation at the same time
                    dirty_next = 1;
                    case (offset_i)
                        2'b00: wdata = {mem_rdata[127:32], proc_wdata[31:0]};
                        2'b01: wdata = {mem_rdata[127:64], proc_wdata[31:0], mem_rdata[31:0]};
                        2'b10: wdata = {mem_rdata[127:95], proc_wdata[31:0], mem_rdata[63:0]};
                        2'b11: wdata = {proc_wdata, mem_rdata[95:0]};
                    endcase
                end else begin
                    wdata = mem_rdata;
                    dirty_next = 0;
                end
            end else begin
                state_w = S_FETCH;
            end
        end
    endcase
end


always @(*) begin:rdata_select
    rdata = 0;
    case (hit_tmp) 
        2'b01: rdata = rdata_sets[0];
        2'b10: rdata = rdata_sets[1];
    endcase
end
always @(*) begin: replace
    replace_sel = 0;
    if (!valid_sets[0]) begin
        replace_sel = 0;
    end else if(!valid_sets[1]) begin
        replace_sel = 1;
    end else begin
        case (hit_tmp) 
            // select the set for read/write
            2'b01: replace_sel = 0;
            2'b10: replace_sel = 1;
            2'b00: replace_sel = lru_lines_r[index_i];
        endcase
    end 
end
always @(*) begin: set_control_signal
    for (i = 0; i < WAYS; i = i + 1) begin
        wen_sets[i] = (i == replace_sel) ? wen : 0;
        update_sets[i] = (i == replace_sel) ? update : 0;
    end
end

//==== sequential circuit =================================
always @(posedge clk) begin
    if (proc_reset) begin
        state_r <= S_IDLE;
        for (i = 0;i < LINE_NUM; i = i + 1) begin
            lru_lines_r[i] <= 0;
        end
    end else begin
        state_r <= state_w;
        for (i = 0;i < LINE_NUM; i = i + 1) begin
            lru_lines_r[i] <= lru_lines_w[i];
        end
    end
end



endmodule

module set #(
    parameter LINE_NUM = 4,
    parameter TAG_WIDTH = 26,
    parameter BLOCK_WIDTH = 128
)(
    input clk,
    input rst,
    input write_i,
    input update_i,
    input valid_i,
    input dirty_i,
    input input_src_i, // input_src_i = 0: CPU, 1: memory
    input [BLOCK_WIDTH-1:0] wdata_i,
    input [29:0] addr_i,
    output        valid_o,
    output        dirty_o,
    output        hit_o, 
    output [TAG_WIDTH-1:0] tag_o,
    output [BLOCK_WIDTH-1:0] rdata_o
);

/* data read from cache line */
wire                      valid_lines [0:LINE_NUM-1];
wire                      dirty_lines [0:LINE_NUM-1];
wire    [TAG_WIDTH-1:0]   tag_lines   [0:LINE_NUM-1];
wire    [BLOCK_WIDTH-1:0] rdata_lines [0:LINE_NUM-1];

/* information from input addr */
wire    [TAG_WIDTH-1:0]            tag_i;
wire    [1:0]             index_i;
wire    [1:0]             offset_i;

/* generate signal */
wire                      valid;
wire                      dirty;
wire                      hit;
wire    [BLOCK_WIDTH-1:0] rdata;
wire    [1:0]             offset;

/* control signal for cache lines */
reg                       wen_lines    [0:LINE_NUM-1]; // write enable signal for each line
wire                      valid_next; // updated valid signal
wire                      dirty_next; // updated dirty signal
reg     [BLOCK_WIDTH-1:0] wdata;      // data written to cache line, the source could by CPU or memory

genvar gen_i;
integer i;
assign {tag_i, index_i, offset_i} = addr_i;

assign valid = valid_lines[index_i];
assign dirty = dirty_lines[index_i];
assign rdata  = rdata_lines[index_i];
assign hit  = (valid && (tag_i == tag_lines[index_i]));

/* output assignment */
assign valid_o = valid;
assign hit_o = hit;
assign rdata_o = rdata;
assign dirty_o = dirty;
assign tag_o = tag_lines[index_i];
/* instantiate cache lines */
generate
    for (gen_i = 0; gen_i < LINE_NUM; gen_i = gen_i + 1) begin:gen_blk2
        line l(
            .clk(clk),
            .rst(rst),
            .write_i(wen_lines[gen_i]),
            .valid_i(valid_next),
            .dirty_i(dirty_next),
            .tag_i(tag_i),
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
    parameter TAG_WIDTH = 26,
    parameter BLOCK_WIDTH = 128,
    parameter WORD_WIDTH = 32
)(
    input clk,
    input rst,
    input write_i,
    input valid_i,
    input dirty_i,
    input [TAG_WIDTH-1:0] tag_i,
    input [BLOCK_WIDTH-1:0] wdata_i,
    output valid_o,
    output dirty_o,
    output [TAG_WIDTH-1:0] tag_o,
    output [BLOCK_WIDTH-1:0] rdata_o
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
assign rdata_o = data_r;

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
        data_r <= 0;
    end else begin
        valid_r <= valid_w;
        dirty_r <= dirty_w;
        tag_r <= tag_w;
        data_r <= data_w;
    end
end
endmodule