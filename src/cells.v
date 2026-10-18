/*
 * SPACE RUN - Tiny Tapeout VGA game (sky130)
 *
 * A spaceship seen from behind flies toward the vanishing point in the
 * middle of the screen. It never moves forward; the stars stream outward
 * past it instead. Asteroids come out of the centre and grow as they
 * approach. Steer left / right to dodge them.
 *
 *   Clock   : 25.175 MHz (one pixel per clock), 640x480 @ 60 Hz
 *   Video   : TinyVGA PMOD on uo_out (2 bits per colour)
 *   Inputs  : ui_in[0] = left, ui_in[1] = right (buttons / switches)
 *             ui_in[4..6] = Tiny Tapeout Gamepad PMOD (D-pad left/right)
 *
 * Area-saving tricks (no multipliers anywhere):
 *   - stars and asteroids sit in shift chains; during vertical blanking the
 *     chain is rotated once and every entry passes through ONE shared
 *     update circuit
 *   - perspective = position grows by a fixed fraction of itself per frame
 *   - every stored star is also drawn point-mirrored (~x, ~y) for free
 *
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_space_run (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    localparam NS = 16;   // stored stars (32 visible because of mirroring)
    localparam SW = 25;   // star word : x[24:12] (s13, 3 frac) y[11:0] (s12, 3 frac)
    localparam NR = 3;    // asteroids
    localparam RW = 26;   // rock word : x[25:12] (s14, 3 frac) y[11:0] (u12, 3 frac)

    wire rst = ~rst_n;

    // ------------------------------------------------------------------
    // VGA timing 640x480: 800 x 525, negative syncs
    // ------------------------------------------------------------------
    reg [9:0] hc, vc;
    always @(posedge clk) begin
        if (rst) begin
            hc <= 0;
            vc <= 0;
        end else if (hc == 10'd799) begin
            hc <= 0;
            vc <= (vc == 10'd524) ? 10'd0 : vc + 10'd1;
        end else begin
            hc <= hc + 10'd1;
        end
    end

    wire visible = (hc < 10'd640) && (vc < 10'd480);
    wire hsync   = ~((hc >= 10'd656) && (hc < 10'd752));
    wire vsync   = ~((vc >= 10'd490) && (vc < 10'd492));

    // beam position relative to the screen centre
    wire signed [10:0] hx = $signed({1'b0, hc}) - 11'sd320;
    wire signed [10:0] vy = $signed({1'b0, vc}) - 11'sd240;

    // work slots during vertical blanking
    wire star_upd   = (vc == 10'd480) && (hc < NS);
    wire rock_upd   = (vc == 10'd480) && (hc >= 10'd64) && (hc < 10'd64 + NR);
    wire frame_tick = (vc == 10'd481) && (hc == 10'd0);

    // ------------------------------------------------------------------
    // Inputs: plain buttons + Gamepad PMOD
    // ------------------------------------------------------------------
    reg [1:0] bl_s, br_s;
    reg [2:0] gp_latch, gp_clk;
    reg [1:0] gp_data;
    reg [11:0] gp_shift, gp_reg;
    always @(posedge clk) begin
        if (rst) begin
            bl_s <= 0; br_s <= 0;
            gp_latch <= 0; gp_clk <= 0; gp_data <= 0;
            gp_shift <= 12'hFFF; gp_reg <= 12'hFFF;
        end else begin
            bl_s     <= {bl_s[0], ui_in[0]};
            br_s     <= {br_s[0], ui_in[1]};
            gp_latch <= {gp_latch[1:0], ui_in[4]};
            gp_clk   <= {gp_clk[1:0],   ui_in[5]};
            gp_data  <= {gp_data[0],    ui_in[6]};
            if (gp_clk[1] & ~gp_clk[2])     gp_shift <= {gp_shift[10:0], gp_data[1]};
            if (gp_latch[1] & ~gp_latch[2]) gp_reg   <= gp_shift;
        end
    end
    // gp_reg = {b, y, select, start, up, down, left, right, a, x, l, r}; all ones = no pad
    wire gp_ok = (gp_reg != 12'hFFF);
    wire mv_l  = bl_s[1] | (gp_ok & gp_reg[5]);
    wire mv_r  = br_s[1] | (gp_ok & gp_reg[4]);

    // ------------------------------------------------------------------
    // Random numbers
    // ------------------------------------------------------------------
    reg [15:0] lfsr;
    always @(posedge clk)
        if (rst) lfsr <= 16'hACE1;
        else     lfsr <= {1'b0, lfsr[15:1]} ^ (lfsr[0] ? 16'hB400 : 16'h0000);

    // ------------------------------------------------------------------
    // Game state
    // ------------------------------------------------------------------
    reg signed [9:0] ship_off;     // ship x relative to centre
    reg [1:0] tilt;                // 01 banking right, 11 banking left
    reg [1:0] lives;
    reg [5:0] score;
    reg [5:0] hit_timer;
    reg [6:0] go_timer;
    reg       game_over;
    reg [4:0] frame_cnt;
    reg       hit_acc;
    reg [1:0] dodge_acc;
    wire [1:0] lvl = score[5:4];   // game speeds up every 16 dodges

    // ==================================================================
    //  STAR FIELD
    // ==================================================================
    reg [NS*SW-1:0] stars;

    wire [SW-1:0]      st_top = stars[(NS-1)*SW +: SW];
    wire signed [12:0] tx     = st_top[24:12];
    wire signed [11:0] ty     = st_top[11:0];
    // NOTE: arithmetic shifts are written out as explicit sign extension
    // instead of >>> (some simulators, e.g. the JS-based VGA playground,
    // get >>> wrong for negative numbers)
    wire [12:0] tx_d32 = {{5{tx[12]}}, tx[12:5]};                  // tx / 32
    wire [11:0] ty_d32 = {{5{ty[11]}}, ty[11:5]};                  // ty / 32
    wire signed [12:0] tnx    = tx + tx_d32 + (tx[12] ? 13'h1FFF : 13'h0001);
    wire signed [11:0] tny    = ty + ty_d32 + (ty[11] ? 12'hFFF  : 12'h001);
    wire t_out = (tx > 13'sd2560) || (tx < -13'sd2560) ||    // |x| > 320 px
                 (ty > 12'sd1920) || (ty < -12'sd1920);      // |y| > 240 px
    wire [SW-1:0] st_new = t_out ?
        { {3{lfsr[6]}},  lfsr[6:0],  3'b000,                  // x: -64..63 px
          {3{lfsr[13]}}, lfsr[13:8], 3'b000 } :               // y: -32..31 px
        { tnx, tny };

    always @(posedge clk)
        if (rst)           stars <= {NS{13'h0FFF, 12'h000}};  // off-screen -> respawn
        else if (star_upd) stars <= {stars[(NS-1)*SW-1:0], st_new};

    wire [NS-1:0]   st_hit;
    wire [2*NS-1:0] st_lv;
    genvar g;
    generate
        for (g = 0; g < NS; g = g + 1) begin : STAR
            wire [SW-1:0] s  = stars[g*SW +: SW];
            wire [9:0]    px = s[24:15];
            wire [8:0]    py = s[11:3];
            wire [10:0]   sx = {px[9], px};
            wire [10:0]   sy = {{2{py[8]}}, py};
            // distance from centre straight from the top bits (no adders)
            wire bigx = ~((px[9:7] == 3'b000)  | (px[9:7] == 3'b111));
            wire bigy = ~((py[8:6] == 3'b000)  | (py[8:6] == 3'b111));
            wire midx = ~((px[9:6] == 4'b0000) | (px[9:6] == 4'b1111));
            wire midy = ~((py[8:5] == 4'b0000) | (py[8:5] == 4'b1111));
            wire big  = bigx | bigy;
            wire [1:0] lv = big ? 2'd3 : (midx | midy) ? 2'd2 : 2'd1;
            // equality via XOR; all-ones means the beam is on the mirror (~x,~y)
            wire [10:0] m  = big ? 11'h7FE : 11'h7FF;     // big stars are 2x2
            wire [10:0] mx = (hx ^ sx) & m;
            wire [10:0] my = (vy ^ sy) & m;
            assign st_hit[g]        = ((mx == 11'd0) && (my == 11'd0)) || ((mx == m) && (my == m));
            assign st_lv[g*2 +: 2]  = st_hit[g] ? lv : 2'd0;
        end
    endgenerate

    reg [1:0] star_lvl;
    integer i;
    always @* begin
        star_lvl = 2'd0;
        for (i = 0; i < NS; i = i + 1) star_lvl = star_lvl | st_lv[i*2 +: 2];
    end

    // ==================================================================
    //  ASTEROIDS
    //  Spawn at (target/32, 5 px) and grow by a fraction of themselves each
    //  frame, so they travel in a straight line from the centre and reach
    //  `target` when they hit the ship row (160 px below centre).
    // ==================================================================
    reg [NR*RW-1:0] rocks;

    wire [RW-1:0]      rq = rocks[(NR-1)*RW +: RW];
    wire signed [13:0] ux = rq[25:12];
    wire        [11:0] uy = rq[11:0];
    wire [13:0] ux_d16 = {{4{ux[13]}}, ux[13:4]};
    wire [13:0] ux_d32 = {{5{ux[13]}}, ux[13:5]};
    wire [13:0] ux_d64 = {{6{ux[13]}}, ux[13:6]};
    reg  [13:0] gx;
    reg  [11:0] gy;
    always @* begin
        case (lvl)
            2'd0:    begin gx = ux_d32;          gy = (uy >> 5);             end
            2'd1:    begin gx = ux_d32 + ux_d64; gy = (uy >> 5) + (uy >> 6); end
            2'd2:    begin gx = ux_d16;          gy = (uy >> 4);             end
            default: begin gx = ux_d16 + ux_d32; gy = (uy >> 4) + (uy >> 5); end
        endcase
    end
    wire signed [13:0] nux   = ux + gx;
    wire        [11:0] nuy   = uy + gy + 12'd1;
    wire               rk_cross = (uy < 12'd1280) && (nuy >= 12'd1280);
    wire signed [11:0] diff  = {ux[13], ux[13:3]} - {{2{ship_off[9]}}, ship_off};
    wire               coll  = rk_cross && !game_over && (hit_timer == 0) &&
                               (diff < 12'sd52) && (diff > -12'sd52);
    wire               gone  = coll || (nuy >= 12'd2320);
    // respawn: half the time aim near the player
    wire signed [10:0] target = lfsr[15] ? ({ship_off[9], ship_off} + {{4{lfsr[6]}}, lfsr[6:0]})
                                         : {{2{lfsr[8]}}, lfsr[8:0]};
    wire [RW-1:0] rk_new = gone ? { {5{target[10]}}, target[10:2], 12'd40 + {9'd0, lfsr[11:9]} }
                                : { nux, nuy };

    always @(posedge clk) begin
        if (rst) begin
            rocks     <= { 14'sd0, 12'd40,  -14'sd60, 12'd300,  14'sd300, 12'd700 };
            hit_acc   <= 1'b0;
            dodge_acc <= 2'd0;
        end else if (rock_upd) begin
            rocks <= {rocks[(NR-1)*RW-1:0], rk_new};
            if (coll) hit_acc <= 1'b1;
            if (rk_cross && !coll && !game_over) dodge_acc <= dodge_acc + 2'd1;
        end else if (frame_tick) begin
            hit_acc   <= 1'b0;
            dodge_acc <= 2'd0;
        end
    end

    wire [NR-1:0] rk_on;
    wire [6*NR-1:0] rk_col;
    generate
        for (g = 0; g < NR; g = g + 1) begin : ROCK
            wire [RW-1:0]      q   = rocks[g*RW +: RW];
            wire signed [10:0] rxp = q[25:15];
            wire        [8:0]  ryp = q[11:3];
            wire        [5:0]  r   = ryp[8:3] + {1'b0, ryp[8:4]} + 6'd1;
            wire signed [11:0] dx  = {hx[10], hx} - {rxp[10], rxp};
            wire signed [11:0] dy  = {vy[10], vy} - {3'b000, ryp};
            wire        [11:0] adx = dx[11] ? -dx : dx;
            wire        [11:0] ady = dy[11] ? -dy : dy;
            wire        [12:0] sum = {1'b0, adx} + {1'b0, ady};
            wire        [12:0] lim = {7'd0, r} + {8'd0, r[5:1]};
            wire rk_in = (adx <= {6'd0, r}) && (ady <= {6'd0, r}) && (sum <= lim);  // octagon
            wire signed [12:0] diag = {dx[11], dx} + {dy[11], dy};
            wire signed [12:0] rh   = {8'd0, r[5:1]};
            wire light = diag < -rh;      // lit from the top-left
            wire dark  = diag >  rh;
            assign rk_on[g]         = rk_in;
            assign rk_col[g*6 +: 6] = light ? 6'b11_10_01 : dark ? 6'b01_00_00 : 6'b10_01_00;
        end
    endgenerate

    reg [5:0] rock_col;
    integer j;
    always @* begin
        rock_col = 6'd0;
        for (j = NR - 1; j >= 0; j = j - 1)
            if (rk_on[j]) rock_col = rk_col[j*6 +: 6];
    end
    wire rock_on = |rk_on;

    // ==================================================================
    //  DISTANT STARS: fixed faint sprinkle, ~1 per 32 cells of 8x8 px,
    //  picked by hashing the cell number (no storage needed)
    // ==================================================================
    wire [12:0] far_cell = {hc[9:3], vc[8:3]};
    wire [12:0] h1   = far_cell ^ {far_cell[7:0], far_cell[12:8]} ^ 13'h1A5B;
    wire [12:0] h2   = h1 ^ {h1[3:0], h1[12:4]} ^ (h1 & {h1[10:0], h1[12:11]});
    wire far_star    = (h2[12:8] == 5'b10110) && (hc[2:0] == h2[2:0]) && (vc[2:0] == h2[5:3]);
    wire [5:0] far_col = h2[6] ? 6'b01_01_01 : 6'b01_01_10;

    // ==================================================================
    //  SPACESHIP seen from behind (centre at 170 px below screen centre)
    //  Light comes from the top-left: left-facing surfaces are brighter.
    // ==================================================================
    wire signed [11:0] sdx  = {hx[10], hx} - {{2{ship_off[9]}}, ship_off};
    wire signed [11:0] sdy0 = {vy[10], vy} - 12'sd170;
    wire        [11:0] sdx8 = {{3{sdx[11]}}, sdx[11:3]};          // sdx / 8
    wire signed [11:0] tlt  = (tilt == 2'b01) ?  sdx8 :
                              (tilt == 2'b11) ? -sdx8 : 12'd0;
    wire signed [11:0] sdy  = sdy0 - tlt;                      // banking shear
    wire        [11:0] sadx = sdx[11] ? -sdx : sdx;
    wire               left = sdx[11];
    wire               near = (sadx < 12'd92) && (sdy > -12'sd60) && (sdy < 12'sd50);

    // fuselage, narrowing toward the vanishing point
    wire signed [11:0] fy   = sdy + 12'sd50;
    wire        [11:0] hw   = 12'd3 + {2'b00, fy[11:2]};
    wire fus     = near && !fy[11] && (sdy <= 12'sd20) && (sadx <= hw);
    wire fus_out = (sadx > {1'b0, hw[11:1]});                  // outer half = curved side
    wire spine   = (sadx <= 12'd1);
    wire stripe  = (sdy >= 12'sd0) && (sdy <= 12'sd3);

    // cockpit canopy with frame
    wire signed [11:0] cpy  = sdy + 12'sd28;
    wire        [11:0] acpy = cpy[11] ? -cpy : cpy;
    wire        [11:0] cpd  = {sadx[10:0], 1'b0} + acpy;
    wire cockpit = near && (cpd <= 12'd16);
    wire cp_rim  = (cpd >= 12'd13);
    wire glare   = left && (sadx >= 12'd1) && (sadx <= 12'd3) && (cpy < -12'sd2);

    // engine block with bevelled lower corners
    wire eng_blk  = near && (sdy >= 12'sd6) && (sdy <= 12'sd24) && (sadx <= 12'd19) &&
                    (sadx + sdy <= 12'd41);
    wire blk_top  = (sdy <= 12'sd7);

    // twin engine bells (octagons)
    wire signed [11:0] ndx  = $signed(sadx) - 12'sd10;
    wire signed [11:0] ndy  = sdy - 12'sd16;
    wire        [11:0] andx = ndx[11] ? -ndx : ndx;
    wire        [11:0] andy = ndy[11] ? -ndy : ndy;
    wire        [12:0] nsum = {1'b0, andx} + {1'b0, andy};
    wire eng_box  = near && (andx <= 12'd7) && (andy <= 12'd7);
    wire eng_rim  = eng_box && (nsum <= 13'd10);
    wire eng_in   = eng_box && (nsum <= 13'd7);
    wire eng_hot  = eng_box && (nsum <= 13'd5);
    wire eng_core = eng_box && (nsum <= 13'd2);

    // swept wings: leading edge, top surface, panel line, underside
    wire signed [11:0] wtop = $signed({2'b00, sadx[11:2]}) - 12'sd2;
    wire signed [11:0] wbot = wtop + 12'sd9 - $signed({4'b0000, sadx[11:4]});
    wire wing     = near && (sadx > 12'd8) && (sadx <= 12'd84) && (sdy >= wtop) && (sdy <= wbot);
    wire wing_le  = (sdy == wtop);
    wire wing_top = (sdy <= wtop + 12'sd3);
    wire wing_pnl = (sdy == wtop + 12'sd2) && (sadx >= 12'd24) && (sadx <= 12'd60);
    wire wing_tip = (sadx >= 12'd74);

    // wing cannons
    wire cannon   = near && (sadx >= 12'd50) && (sadx <= 12'd52) &&
                    (sdy >= wtop - 12'sd7) && (sdy < wtop);
    wire muzzle   = (sdy == wtop - 12'sd7);

    // tail fins leaning outward
    wire signed [11:0] fz   = 12'sd4 - sdy;
    wire        [11:0] fx   = 12'd27 + {2'b00, fz[11:2]};
    wire fin      = near && (sdy >= -12'sd16) && (sdy < wtop) && !fz[11] &&
                    (sadx >= fx) && (sadx <= fx + 12'd3);
    wire fin_tip  = (sdy < -12'sd11);

    // flickering exhaust
    wire signed [11:0] ply  = sdy - 12'sd24;
    wire        [11:0] plen = 12'd12 + {9'd0, frame_cnt[2:1], 1'b0};
    wire plume = near && !ply[11] && (ply <= $signed(plen)) &&
                 (andx <= ((plen - ply) >> 2) + 12'd1);

    reg [5:0] ship_col;   // RRGGBB
    reg       ship_on;
    always @* begin
        ship_on = 1'b1;
        if (cockpit)       ship_col = cp_rim ? 6'b01_01_01 : glare ? 6'b10_11_11 : 6'b00_01_10;
        else if (eng_core) ship_col = frame_cnt[1] ? 6'b11_11_10 : 6'b11_11_01;
        else if (eng_hot)  ship_col = 6'b11_10_00;
        else if (eng_in)   ship_col = 6'b10_00_00;
        else if (eng_rim)  ship_col = left ? 6'b10_10_10 : 6'b01_01_01;
        else if (eng_blk)  ship_col = blk_top ? 6'b10_10_10 : (left ? 6'b01_01_01 : 6'b00_00_01);
        else if (fus)      ship_col = stripe  ? (left ? 6'b11_00_00 : 6'b10_00_00) :
                                      spine   ? 6'b11_11_11 :
                                      fus_out ? (left ? 6'b11_11_11 : 6'b01_01_01) :
                                                (left ? 6'b10_10_11 : 6'b10_10_10);
        else if (fin)      ship_col = fin_tip ? 6'b11_00_00 : (left ? 6'b10_10_11 : 6'b01_01_01);
        else if (cannon)   ship_col = muzzle ? 6'b11_11_11 : 6'b10_10_10;
        else if (wing) begin
            if (wing_tip)       // navigation lights: red left, green right
                ship_col = (sadx >= 12'd81 && frame_cnt[3]) ? 6'b11_11_11 :
                           left ? (wing_top ? 6'b11_00_00 : 6'b10_00_00)
                                : (wing_top ? 6'b00_11_00 : 6'b00_10_00);
            else if (wing_le)  ship_col = left ? 6'b11_11_11 : 6'b10_10_10;
            else if (wing_pnl) ship_col = left ? 6'b01_01_10 : 6'b00_00_01;
            else if (wing_top) ship_col = left ? 6'b10_10_11 : 6'b01_01_01;
            else               ship_col = left ? 6'b01_01_10 : 6'b00_00_01;
        end
        else if (plume)    ship_col = (ply < 12'sd4)  ? 6'b11_11_10 :
                                      (ply < 12'sd9)  ? 6'b11_10_00 : 6'b10_00_00;
        else begin
            ship_on  = 1'b0;
            ship_col = 6'd0;
        end
        if (hit_timer != 0 && hit_timer[2]) ship_on = 1'b0;     // blink after a hit
        if (game_over) ship_col = {ship_col[5:4], 4'b0000};     // burnt red
    end

    // ==================================================================
    //  Game logic, once per frame
    // ==================================================================
    always @(posedge clk) begin
        if (rst) begin
            ship_off  <= 10'sd0;
            tilt      <= 2'b00;
            lives     <= 2'd3;
            score     <= 6'd0;
            hit_timer <= 6'd0;
            go_timer  <= 7'd0;
            game_over <= 1'b0;
            frame_cnt <= 5'd0;
        end else if (frame_tick) begin
            frame_cnt <= frame_cnt + 5'd1;

            if (!game_over && mv_l && !mv_r) begin
                tilt <= 2'b11;
                if (ship_off > -10'sd228) ship_off <= ship_off - 10'sd7;
            end else if (!game_over && mv_r && !mv_l) begin
                tilt <= 2'b01;
                if (ship_off < 10'sd228) ship_off <= ship_off + 10'sd7;
            end else
                tilt <= 2'b00;

            if (hit_timer != 0) hit_timer <= hit_timer - 6'd1;
            if (go_timer  != 0) go_timer  <= go_timer  - 7'd1;

            if ({1'b0, score} + {5'd0, dodge_acc} > 7'd63) score <= 6'd63;
            else                                          score <= score + {4'd0, dodge_acc};

            if (hit_acc) begin
                hit_timer <= 6'd60;
                if (lives <= 2'd1) begin
                    lives     <= 2'd0;
                    game_over <= 1'b1;
                    go_timer  <= 7'd90;
                end else
                    lives <= lives - 2'd1;
            end

            if (game_over && go_timer == 0 && (mv_l || mv_r)) begin
                game_over <= 1'b0;
                lives     <= 2'd3;
                score     <= 6'd0;
                hit_timer <= 6'd40;     // short grace period
                ship_off  <= 10'sd0;
            end
        end
    end

    // ==================================================================
    //  HUD + final colour
    // ==================================================================
    wire hud_row = (vc >= 10'd12) && (vc < 10'd24);
    wire life0   = hud_row && (lives > 2'd0) && (hc >= 10'd12) && (hc < 10'd24);
    wire life1   = hud_row && (lives > 2'd1) && (hc >= 10'd30) && (hc < 10'd42);
    wire life2   = hud_row && (lives > 2'd2) && (hc >= 10'd48) && (hc < 10'd60);
    wire bar     = (vc >= 10'd15) && (vc < 10'd21) && (hc >= 10'd80) &&
                   (hc < 10'd80 + {1'b0, score, 3'b000});
    wire border  = game_over && ((hc < 10'd8) || (hc >= 10'd632) || (vc < 10'd8) || (vc >= 10'd472));

    reg [5:0] color;
    always @* begin
        if (life0 || life1 || life2) color = 6'b00_11_00;
        else if (bar)                color = 6'b11_11_00;
        else if (border)             color = frame_cnt[4] ? 6'b11_00_00 : 6'b10_00_00;
        else if (ship_on)            color = ship_col;
        else if (rock_on)            color = rock_col;
        else if (star_lvl == 2'd1)   color = 6'b10_10_10;
        else if (star_lvl != 2'd0)   color = 6'b11_11_11;
        else if (far_star)           color = far_col;
        else if (hit_timer > 6'd52)  color = 6'b01_00_00;         // impact flash
        else                         color = 6'b00_00_00;
    end

    // registered outputs
    reg       hs_r, vs_r;
    reg [5:0] rgb;
    always @(posedge clk) begin
        if (rst) begin
            hs_r <= 1'b1;
            vs_r <= 1'b1;
            rgb  <= 6'd0;
        end else begin
            hs_r <= hsync;
            vs_r <= vsync;
            rgb  <= visible ? color : 6'd0;
        end
    end

    // TinyVGA PMOD: {hsync, B0, G0, R0, vsync, B1, G1, R1}
    assign uo_out  = {hs_r, rgb[0], rgb[2], rgb[4], vs_r, rgb[1], rgb[3], rgb[5]};
    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    wire _unused = &{ena, uio_in, ui_in[7], ui_in[3:2], 1'b0};

endmodule

