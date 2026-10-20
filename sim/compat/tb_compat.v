`timescale 1ns/1ps
module tb_compat;
    reg clk=0,pclk=0;
    always #9.286 clk=~clk;
`ifdef HZ120
    always #9.259 pclk=~pclk;
    localparam FH=480;
`else
    always #6.734 pclk=~pclk;
    localparam FH=720;
`endif
    reg [10:0] W=320;
    reg [9:0] H=224;
    reg full=0,scan=0,thick=0,overlay=0;
    reg [1:0] darkness=2;
    reg [31:0] vcfg=0;
    framebuffer dut(
        .clk(clk),.resetn(1'b1),.clk_pixel(pclk),.clk_5x_pixel(1'b0),
        .hblank(1'b0),.vblank(1'b0),.ce_pix(1'b0),.r(4'd0),.g(4'd0),.b(4'd0),.x(9'd0),.y(8'd0),
        .width(W),.height(H),.interlace(1'b0),.double_res(1'b0),.field(1'b0),.pause_core(),
        .overlay(overlay),.overlay_x(),.overlay_y(),.overlay_color(15'h573a),
        .scanlines(scan),.sl_darkness(darkness),.sl_thick(thick),.sl_out(full),.video_config(vcfg),
        .std_timing(1'b0),.audio_left(16'd0),.audio_right(16'd0),
        .tmds_clk_n(),.tmds_clk_p(),.tmds_d_n(),.tmds_d_p());
    framebuffer_base base(
        .clk(clk),.resetn(1'b1),.clk_pixel(pclk),.clk_5x_pixel(1'b0),
        .ce_pix(1'b0),.r(4'd0),.g(4'd0),.b(4'd0),.x(9'd0),.y(8'd0),
        .width(W),.height(H),.pause_core(),
        .overlay(overlay),.overlay_x(),.overlay_y(),.overlay_color(15'h573a),
        .scanlines(scan),.sl_darkness(darkness),.sl_thick(thick),.sl_out(full),.video_config(vcfg),
        .std_timing(1'b0),.audio_left(16'd0),.audio_right(16'd0),
        .tmds_clk_n(),.tmds_clk_p(),.tmds_d_n(),.tmds_d_p());
    integer compared=0,cases=0;
    reg checking=0;
    always @(negedge pclk) if(checking) begin
        if(dut.cx!==base.cx || dut.cy!==base.cy || dut.rgb!==base.rgb || dut.overlay_x!==base.overlay_x || dut.overlay_y!==base.overlay_y)
            $fatal(1,"progressive mismatch at %0d,%0d got=%h base=%h",dut.cx,dut.cy,dut.rgb,base.rgb);
        compared++;
    end
    task frame;
        begin
            @(negedge pclk);while(dut.cy!=FH+2) @(negedge pclk);
            while(dut.cy==FH+2) @(negedge pclk);
        end
    endtask
    integer x,y,a,w,h,f,sl;
    reg [11:0] color;
    initial begin
        dut.pause_prog=0;base.pause_core=0;
        for(y=0;y<240;y++) for(x=0;x<320;x++) begin
`ifdef HZ120
            a=y*320+x;
`else
            a=(y%32)*320+x;
`endif
            color=(x*11+y*31)%4096;dut.mem[a]=color;base.mem[a]=color;
        end
        for(w=0;w<2;w++) for(h=0;h<2;h++) for(f=0;f<2;f++) for(sl=0;sl<3;sl++) begin
            W=w?256:320;H=h?240:224;full=f;scan=(sl!=0);thick=(sl==2);
            frame;frame;checking=1;frame;checking=0;cases++;
        end
        overlay=1;frame;frame;checking=1;frame;checking=0;cases++;
        $display("tb_compat: PASS %0d cases, %0d clocks/pixels compared to int/round7",cases,compared);$finish;
    end
endmodule
