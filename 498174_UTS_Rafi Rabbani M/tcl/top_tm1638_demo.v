// ============================================================================
// top_tm1638_demo.v
// UTS TKEE262703 Digital IC Design - NIM berjalan di modul TM1638 (LED&KEY)
// Board  : iCESugar V1.5 (iCE40UP5K, clock 12 MHz di pin 35)
// Dasar  : demo basic.v dari github.com/alangarf/tm1638-verilog
//
// NIM 22/498174/TK/54632 ditampilkan sebagai "22-498174-54632"
// ("/" diganti strip, "TK" tidak ditampilkan karena huruf K tidak bisa
//  dibentuk di 7-segment).
//
// Switch 2 bit diambil dari tombol modul TM1638:
//   S1 -> toggle sw[1]   (status terlihat di LED1)
//   S2 -> toggle sw[0]   (status terlihat di LED2)
//   sw = 2'b01 : NIM geser ke kiri setiap 1 detik
//   sw = 2'b10 : NIM geser ke kanan setiap 1 detik
//   sw = 2'b00 : NIM geser bolak-balik kiri-kanan setiap 1 detik
//   sw = 2'b11 : NIM diam
// ============================================================================
module top_tm1638_demo #(
    parameter [23:0] ONE_SEC = 24'd12_000_000   // 12 MHz -> 1 detik
)(
    input  clk,

    output reg tm_cs,
    output tm_clk,
    inout  tm_dio
    );

    localparam
        HIGH    = 1'b1,
        LOW     = 1'b0;

    localparam [7:0]
        C_READ  = 8'b01000010,
        C_WRITE = 8'b01000000,
        C_DISP  = 8'b10001111,
        C_ADDR  = 8'b11000000;

    localparam CLK_DIV = 19; // counter 20 bit, &counter tiap ~87 ms

    // ------------------------------------------------------------------
    // Karakter dan teks NIM
    // ------------------------------------------------------------------
    // kode karakter 4 bit: 0-9 = angka, 10 = strip, 15 = kosong
    localparam [3:0]
        CH_DASH = 4'd10,
        CH_BLK  = 4'd15;

    // jumlah karakter teks = 15, jendela display = 8 digit
    // posisi awal jendela maksimum untuk mode bolak-balik = 15 - 8 = 7
    localparam [3:0] POS_MAX = 4'd7;

    // kode karakter -> segmen (urutan bit g f e d c b a)
    function [6:0] seg_of;
        input [3:0] ch;
        case (ch)
            4'd0:    seg_of = 7'b0111111;
            4'd1:    seg_of = 7'b0000110;
            4'd2:    seg_of = 7'b1011011;
            4'd3:    seg_of = 7'b1001111;
            4'd4:    seg_of = 7'b1100110;
            4'd5:    seg_of = 7'b1101101;
            4'd6:    seg_of = 7'b1111101;
            4'd7:    seg_of = 7'b0000111;
            4'd8:    seg_of = 7'b1111111;
            4'd9:    seg_of = 7'b1101111;
            CH_DASH: seg_of = 7'b1000000;
            default: seg_of = 7'b0000000;   // kosong
        endcase
    endfunction

    // teks "22-498174-54632" + 1 spasi = 16 karakter (indeks 0..15)
    // 16 = 2^4, jadi indeks 4 bit otomatis berputar (15 + 1 = 0)
    function [3:0] nim_char;
        input [3:0] idx;
        case (idx)
            4'd0:    nim_char = 4'd2;
            4'd1:    nim_char = 4'd2;
            4'd2:    nim_char = CH_DASH;
            4'd3:    nim_char = 4'd4;
            4'd4:    nim_char = 4'd9;
            4'd5:    nim_char = 4'd8;
            4'd6:    nim_char = 4'd1;
            4'd7:    nim_char = 4'd7;
            4'd8:    nim_char = 4'd4;
            4'd9:    nim_char = CH_DASH;
            4'd10:   nim_char = 4'd5;
            4'd11:   nim_char = 4'd4;
            4'd12:   nim_char = 4'd6;
            4'd13:   nim_char = 4'd3;
            4'd14:   nim_char = 4'd2;
            default: nim_char = CH_BLK;     // indeks 15 = spasi pemisah
        endcase
    endfunction

    reg rst = HIGH;

    reg [5:0] instruction_step;
    reg [7:0] keys;
    reg [CLK_DIV:0] counter;

    // ------------------------------------------------------------------
    // Register untuk animasi NIM
    // ------------------------------------------------------------------
    reg [1:0]  sw;          // "switch": sw[1] dari S1, sw[0] dari S2
    reg [7:0]  keys_prev;   // status tombol sampel sebelumnya (deteksi tepi)
    reg [23:0] sec_cnt;     // pembagi clock 1 detik
    reg [3:0]  pos;         // indeks karakter yang tampil di digit paling kiri
    reg        bounce_dir;  // mode 00: 0 = sedang geser kiri, 1 = sedang geser kanan

    // 8 karakter yang sedang tampil, digit 1 (kiri) sampai digit 8 (kanan)
    wire [6:0] seg_d1 = seg_of(nim_char(pos));
    wire [6:0] seg_d2 = seg_of(nim_char(pos + 4'd1));
    wire [6:0] seg_d3 = seg_of(nim_char(pos + 4'd2));
    wire [6:0] seg_d4 = seg_of(nim_char(pos + 4'd3));
    wire [6:0] seg_d5 = seg_of(nim_char(pos + 4'd4));
    wire [6:0] seg_d6 = seg_of(nim_char(pos + 4'd5));
    wire [6:0] seg_d7 = seg_of(nim_char(pos + 4'd6));
    wire [6:0] seg_d8 = seg_of(nim_char(pos + 4'd7));

    // LED1 = sw[1], LED2 = sw[0], LED lain mati
    // dibaca kiri ke kanan, LED1-LED2 menunjukkan nilai switch dalam biner
    wire [7:0] led_bits = {6'b0, sw[0], sw[1]};

    // ------------------------------------------------------------------
    // Pin tristate DIO (tidak diubah dari demo asli)
    // ------------------------------------------------------------------
    reg tm_rw;
    wire dio_in, dio_out;
    SB_IO #(
        .PIN_TYPE(6'b101001),
        .PULLUP(1'b1)
    ) tm_dio_io (
        .PACKAGE_PIN(tm_dio),
        .OUTPUT_ENABLE(tm_rw),
        .D_IN_0(dio_in),
        .D_OUT_0(dio_out)
    );

    // ------------------------------------------------------------------
    // Driver TM1638 (tidak diubah dari demo asli)
    // ------------------------------------------------------------------
    reg tm_latch;
    wire busy;
    wire [7:0] tm_data, tm_in;
    reg [7:0] tm_out;

    assign tm_in = tm_data;
    assign tm_data = tm_rw ? tm_out : 8'hZZ;

    tm1638 u_tm1638 (
        .clk(clk),
        .rst(rst),
        .data_latch(tm_latch),
        .data(tm_data),
        .rw(tm_rw),
        .busy(busy),
        .sclk(tm_clk),
        .dio_in(dio_in),
        .dio_out(dio_out)
    );

    // kirim satu digit; titik desimal menyala selama tombol di bawahnya ditekan
    task display_digit;
        input [2:0] key;
        input [6:0] segs;

        begin
            tm_latch <= HIGH;
            tm_out   <= {keys[key], segs};
        end
    endtask

    // kirim status satu LED
    task display_led;
        input [2:0] dot;

        begin
            tm_latch <= HIGH;
            tm_out   <= {7'b0, led_bits[dot]};
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            instruction_step <= 6'b0;
            tm_cs <= HIGH;
            tm_rw <= HIGH;
            rst <= LOW;

            counter    <= 0;
            keys       <= 8'b0;

            sw         <= 2'b00;
            keys_prev  <= 8'b0;
            sec_cnt    <= 24'd0;
            pos        <= 4'd0;
            bounce_dir <= 1'b0;

        end else begin
            // ----------------------------------------------------------
            // Tombol S1/S2 sebagai switch toggle.
            // Disampling tiap ~87 ms, sekaligus berfungsi sebagai debounce.
            // ----------------------------------------------------------
            if (&counter) begin
                keys_prev <= keys;
                if (keys[7] & ~keys_prev[7]) sw[1] <= ~sw[1];   // S1 baru ditekan
                if (keys[6] & ~keys_prev[6]) sw[0] <= ~sw[0];   // S2 baru ditekan
            end

            // ----------------------------------------------------------
            // Animasi geser setiap 1 detik
            //   pos naik  -> isi display bergeser ke kiri
            //   pos turun -> isi display bergeser ke kanan
            // ----------------------------------------------------------
            if (sec_cnt == ONE_SEC - 1) begin
                sec_cnt <= 24'd0;

                case (sw)
                    2'b01: pos <= pos + 4'd1;                 // geser kiri (berputar)
                    2'b10: pos <= pos - 4'd1;                 // geser kanan (berputar)
                    2'b00: begin                              // bolak-balik
                        if (!bounce_dir) begin
                            if (pos >= POS_MAX) begin
                                bounce_dir <= 1'b1;
                                pos <= pos - 4'd1;
                            end else
                                pos <= pos + 4'd1;
                        end else begin
                            if (pos == 4'd0) begin
                                bounce_dir <= 1'b0;
                                pos <= pos + 4'd1;
                            end else
                                pos <= pos - 4'd1;
                        end
                    end
                    default: ;                                // 2'b11: diam
                endcase
            end else
                sec_cnt <= sec_cnt + 24'd1;

            // ----------------------------------------------------------
            // State machine komunikasi TM1638 (struktur dari demo asli)
            // ----------------------------------------------------------
            if (counter[0] && ~busy) begin
                case (instruction_step)
                    // *** KEYS ***
                    1:  {tm_cs, tm_rw}     <= {LOW, HIGH};
                    2:  {tm_latch, tm_out} <= {HIGH, C_READ}; // read mode
                    3:  {tm_latch, tm_rw}  <= {HIGH, LOW};

                    //  read back keys S1 - S8
                    4:  {keys[7], keys[3]} <= {tm_in[0], tm_in[4]};
                    5:  {tm_latch}         <= {HIGH};
                    6:  {keys[6], keys[2]} <= {tm_in[0], tm_in[4]};
                    7:  {tm_latch}         <= {HIGH};
                    8:  {keys[5], keys[1]} <= {tm_in[0], tm_in[4]};
                    9:  {tm_latch}         <= {HIGH};
                    10: {keys[4], keys[0]} <= {tm_in[0], tm_in[4]};
                    11: {tm_cs}            <= {HIGH};

                    // *** DISPLAY ***
                    12: {tm_cs, tm_rw}     <= {LOW, HIGH};
                    13: {tm_latch, tm_out} <= {HIGH, C_WRITE}; // write mode
                    14: {tm_cs}            <= {HIGH};

                    15: {tm_cs, tm_rw}     <= {LOW, HIGH};
                    16: {tm_latch, tm_out} <= {HIGH, C_ADDR}; // set addr 0 pos

                    17: display_digit(3'd7, seg_d1); // Digit 1
                    18: display_led(3'd0);           // LED 1

                    19: display_digit(3'd6, seg_d2); // Digit 2
                    20: display_led(3'd1);           // LED 2

                    21: display_digit(3'd5, seg_d3); // Digit 3
                    22: display_led(3'd2);           // LED 3

                    23: display_digit(3'd4, seg_d4); // Digit 4
                    24: display_led(3'd3);           // LED 4

                    25: display_digit(3'd3, seg_d5); // Digit 5
                    26: display_led(3'd4);           // LED 5

                    27: display_digit(3'd2, seg_d6); // Digit 6
                    28: display_led(3'd5);           // LED 6

                    29: display_digit(3'd1, seg_d7); // Digit 7
                    30: display_led(3'd6);           // LED 7

                    31: display_digit(3'd0, seg_d8); // Digit 8
                    32: display_led(3'd7);           // LED 8
                    33: {tm_cs}            <= {HIGH};

                    34: {tm_cs, tm_rw}     <= {LOW, HIGH};
                    35: {tm_latch, tm_out} <= {HIGH, C_DISP}; // display on, full bright
                    36: {tm_cs, instruction_step} <= {HIGH, 6'b0};

                endcase

                instruction_step <= instruction_step + 1;

            end else if (busy) begin
                // pull latch low next clock cycle after module has been latched
                tm_latch <= LOW;
            end

            counter <= counter + 1;
        end
    end
endmodule
