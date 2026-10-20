`timescale 1ns/1ps
module tb_hdmi_rate;
    reg clk=0,reset=1,interlace=0,std_timing=0;
    always #1 clk=~clk;
`ifdef HZ120
    localparam VIC=48,NATIVE=858,PROG=450450,ILACE=451440,STD=450450;
`else
    localparam VIC=4,NATIVE=1652,PROG=1239000,ILACE=1241460,STD=1237500;
`endif
    wire [10:0] cx;
    wire [9:0] cy;
    wire [10:0] fw;
    wire [15:0] aud[1:0];
    assign aud[0]=0;assign aud[1]=0;
    hdmi #(.VIDEO_ID_CODE(VIC),.DVI_OUTPUT(1),.NATIVE_FRAME_WIDTH(NATIVE)) dut(
        .clk_pixel_x5(1'b0),.clk_pixel(clk),.clk_audio(1'b0),.reset(reset),
        .std_timing(std_timing),.interlace(interlace),.rgb(24'd0),.audio_sample_word(aud),
        .tmds(),.tmds_clock(),.cx(cx),.cy(cy),.frame_width(fw),.frame_height(),.screen_width(),.screen_height());
    integer count,frames,expected;
    task measure(input integer il,input integer st,input integer want);
        begin
            @(negedge clk);reset=1;interlace=il;std_timing=st;
            @(negedge clk);reset=0;count=0;frames=0;
            while(frames<2) begin
                @(negedge clk);count++;
                if(cx==0 && cy==0) begin
                    if(count!=want) $fatal(1,"HDMI period %0d expected %0d",count,want);
                    frames++;count=0;
                end
            end
            $display("real HDMI ilace=%0d std=%0d period=%0d: PASS",il,st,want);
        end
    endtask
    initial begin
        measure(0,0,PROG);measure(1,0,ILACE);measure(1,1,STD);measure(0,0,PROG);
        $display("tb_hdmi_rate: PASS");$finish;
    end
endmodule
