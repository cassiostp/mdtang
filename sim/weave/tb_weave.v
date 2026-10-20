// Every logical woven row has a distinct RGB4 value; check both parities,
// every output row, Full/Integer, H32/H40, V28/V30, scanlines and the menu.
`timescale 1ns/1ps
module tb_weave;
    reg clk=0, pclk=0;
    always #9.286 clk=~clk;
`ifdef HZ120
    always #9.259259259 pclk=~pclk;
    localparam FH=480, FW=720;
`else
    always #6.734006734 pclk=~pclk;
    localparam FH=720, FW=1280;
`endif
    reg [10:0] W=320;
    reg [9:0] H=224;
    reg full=0, scan=0, thick=0, ov=0;
    reg [1:0] darkness=0;
    wire pause_core;
    framebuffer dut(
        .clk(clk),.resetn(1'b1),.clk_pixel(pclk),.clk_5x_pixel(1'b0),
        .ce_pix(1'b0),.hblank(1'b1),.vblank(1'b1),.r(4'd0),.g(4'd0),.b(4'd0),.x(9'd0),.y(8'd0),
        .width(W),.height(H),.interlace(1'b1),.double_res(1'b1),.field(1'b0),
        .pause_core(pause_core),.overlay(ov),.overlay_x(),.overlay_y(),.overlay_color(15'h7fff),
        .scanlines(scan),.sl_darkness(darkness),.sl_thick(thick),.sl_out(full),.video_config(32'd0),
        .std_timing(1'b0),.audio_left(16'd0),.audio_right(16'd0),
        .tmds_clk_n(),.tmds_clk_p(),.tmds_d_n(),.tmds_d_p());
    function [11:0] color(input integer n);
        color=12'h400+n;
    endfunction
    function [23:0] rgb(input [11:0] c);
        rgb={c[11:8],4'd0,c[7:4],4'd0,c[3:0],4'd0};
    endfunction
    function [7:0] dim(input [7:0] c, input [1:0] d);
        case(d) 0:dim=c-(c>>2); 1:dim=c>>1; 2:dim=c>>2; 3:dim=0; endcase
    endfunction
    reg [23:0] image[0:FH-1];
    always @(posedge pclk) if(dut.cx==FW/2+1 && dut.cy<FH) image[dut.cy]=dut.rgb;
    task frame;
        begin
            @(negedge pclk);
            while(dut.cy!=FH+2) @(negedge pclk);
            while(dut.cy==FH+2) @(negedge pclk);
        end
    endtask
    integer l,c,row,line,top,n=0;
    reg [23:0] want;
    task check;
        begin
            top=full||ov ? 0 : (FH-2*H)/2;
            for(row=0;row<FH;row=row+1) begin
                line=full ? row*(2*H)/FH : row-top;
                if(ov) want=24'hf8f8f8;
                else if(line<0 || line>=2*H) want=24'h303030;
                else begin
                    want=rgb(color(line));
                    if(scan && row%2==1) want={dim(want[23:16],darkness),dim(want[15:8],darkness),dim(want[7:0],darkness)};
                end
                if(image[row]!==want) $fatal(1,"row=%0d logical=%0d got=%h want=%h W=%0d H=%0d Full=%b scan=%b thick=%b darkness=%d ov=%b",row,line,image[row],want,W,H,full,scan,thick,darkness,ov);
            end
            n=n+1;
            $display("weave %0dx%0d Full=%b scan=%b thick=%b darkness=%d ov=%b: PASS (%0d rows)",W,H*2,full,scan,thick,darkness,ov,FH);
        end
    endtask
    integer wi,hi,f,s,d;
    initial begin
        force dut.ilace_valid=2'b11;
        force dut.ilace_bank_even=0;
        force dut.ilace_bank_odd=1;
        for(l=0;l<480;l=l+1) for(c=0;c<320;c=c+1) dut.mem[(l%2)*76800+(l/2)*320+c]=color(l);
        for(wi=0;wi<2;wi=wi+1) for(hi=0;hi<2;hi=hi+1) begin
            W=wi?256:320;H=hi?240:224;
            for(f=0;f<2;f=f+1) begin
                full=f;
                for(s=0;s<2;s=s+1) begin
                    scan=s;
                    for(d=0;d<(s?4:1);d=d+1) begin
                        darkness=d;thick=d%2;
                        frame;frame;check;
                    end
                end
            end
        end
        ov=1;frame;frame;check;
        $display("tb_weave: PASS %0d cases",n);$finish;
    end
    initial begin #3000000000; $fatal(1,"watchdog"); end
endmodule
