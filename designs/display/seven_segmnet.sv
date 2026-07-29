module seven_segment(
    input logic system_clock, 
    input logic cpu_rst_n,
    input logic [31:0] display_val,
    output logic [6:0] cathodes_out, 
    output logic [7:0] anodes
);

// [8] , [7] , [6] , [5] , [4] , [3] , [2] , [1]

logic [3:0] digit_display;
clock_divider32 clk_div3200(.sys_clk(system_clock), .reset_n(cpu_rst_n), .clk_32(clock_enable));

// -------------------- Rotate Anodes Logic ---------------------

always @(posedge system_clock or negedge cpu_rst_n) begin
    if(!cpu_rst_n) anodes <= 8'b0111_1111;
    else if (clock_enable) anodes <= {anodes[0], anodes[7:1]};
    else anodes <= anodes;
end


always_comb begin
    case(anodes) 
        'b0111_1111: digit_display = display_val[31:28];   //seg8; 
        'b1011_1111: digit_display = display_val[27:24];   //seg7;
        'b1101_1111: digit_display = display_val[23:20];   //seg6;
        'b1110_1111: digit_display = display_val[19:16];   //seg5;
        'b1111_0111: digit_display = display_val[15:12];   //seg4;
        'b1111_1011: digit_display = display_val[11:8];   //seg3;
        'b1111_1101: digit_display = display_val[7:4];   //seg2;
        'b1111_1110: digit_display = display_val[3:0];   //seg1;
        default : digit_display = display_val[31:28];
    endcase
end

always_comb begin

    case (digit_display)
        'd0: cathodes_out = 'b000_0001; // 0
        'd1: cathodes_out = 'b100_1111; // 1
        'd2: cathodes_out = 'b001_0010; // 2
        'd3: cathodes_out = 'b000_0110; // 3
        'd4: cathodes_out = 'b100_1100; // 4
        'd5: cathodes_out = 'b010_0100; // 5
        'd6: cathodes_out = 'b010_0000; // 6
        'd7: cathodes_out = 'b000_1111; // 7
        'd8: cathodes_out = 'b000_0000; // 8
        'd9: cathodes_out = 'b000_0100; // 9
        'd10: cathodes_out = 'b000_1000; // A
        'd11: cathodes_out = 'b110_0000; // B
        'd12: cathodes_out = 'b011_0001; // C
        'd13: cathodes_out = 'b100_0010; // D
        'd14: cathodes_out = 'b011_0000; // E
        'd15: cathodes_out = 'b011_1000; // F
        default: cathodes_out = 'b000_0001; // Default case
    endcase

end 

endmodule