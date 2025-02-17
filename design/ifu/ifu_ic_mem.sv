//********************************************************************************
// SPDX-License-Identifier: Apache-2.0
// Copyright 2019 Western Digital Corporation or it's affiliates.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//********************************************************************************
////////////////////////////////////////////////////
//   ICACHE DATA & TAG MODULE WRAPPER              //
/////////////////////////////////////////////////////
module ifu_ic_mem
  (
      input logic free_clk,
      input logic clk,
      input logic rst_l,
      input logic clk_override,
      input logic dec_tlu_core_ecc_disable,

      input logic [31:2]  ic_rw_addr,
      input logic [3:0]   ic_wr_en  ,  // Which way to write
      input logic         ic_rd_en  ,  // Read enable

      input logic [15:2]               ic_debug_addr,      // Read/Write addresss to the Icache.
      input logic                      ic_debug_rd_en,     // Icache debug rd
      input logic                      ic_debug_wr_en,     // Icache debug wr
      input logic                      ic_debug_tag_array, // Debug tag array
      input logic [3:0]                ic_debug_way,       // Debug way. Rd or Wr.
      input logic [127:0]              ic_premux_data,     // Premux data to be muxed with each way of the Icache.
      input logic                      ic_sel_premux_data, // Select the pre_muxed data


`ifdef RV_ICACHE_RANDOM_PLACEMENT
			input logic [9:0]		real_tag,
`endif

`ifdef RV_ICACHE_ECC
      input  logic [83:0]               ic_wr_data,         // Data to fill to the Icache. With ECC
      output logic [167:0]              ic_rd_data ,        // Data read from Icache. 2x64bits + parity bits. F2 stage. With ECC
      output logic [24:0]               ictag_debug_rd_data,// Debug icache tag.
      input logic  [41:0]               ic_debug_wr_data,   // Debug wr cache.
`else
      input  logic [67:0]               ic_wr_data,         // Data to fill to the Icache. With Parity
      output logic [135:0]              ic_rd_data ,        // Data read from Icache. 2x64bits + parity bits. F2 stage. With Parity
      output logic [20:0]               ictag_debug_rd_data,// Debug icache tag.
      input logic  [33:0]               ic_debug_wr_data,   // Debug wr cache.
`endif


      input logic [3:0]   ic_tag_valid,  // Valid from the I$ tag valid outside (in flops).

      output logic [3:0]   ic_rd_hit,   // ic_rd_hit[3:0]
      output logic         ic_tag_perr, // Tag Parity error
      input  logic         scan_mode
      ) ;

`include "global.h"

   IC_TAG #( .ICACHE_TAG_HIGH(ICACHE_TAG_HIGH) ,
             .ICACHE_TAG_LOW(ICACHE_TAG_LOW) ,
             .ICACHE_TAG_DEPTH(ICACHE_TAG_DEPTH)
             ) ic_tag_inst
          (
           .*,
           .ic_wr_en     (ic_wr_en[3:0]),
           .ic_debug_addr(ic_debug_addr[ICACHE_TAG_HIGH-1:2]),
           .ic_rw_addr   (ic_rw_addr[31:3])
           ) ;

   IC_DATA #( .ICACHE_TAG_HIGH(ICACHE_TAG_HIGH) ,
              .ICACHE_TAG_LOW(ICACHE_TAG_LOW) ,
              .ICACHE_IC_DEPTH(ICACHE_IC_DEPTH)
             ) ic_data_inst
          (
           .*,
           .ic_wr_en     (ic_wr_en[3:0]),
           .ic_debug_addr(ic_debug_addr[ICACHE_TAG_HIGH-1:2]),
           .ic_rw_addr   (ic_rw_addr[ICACHE_TAG_HIGH-1:2]),
           .ic_rw_addr_full(ic_rw_addr[31:3])
           ) ;

 endmodule


/////////////////////////////////////////////////
////// ICACHE DATA MODULE    ////////////////////
/////////////////////////////////////////////////
module IC_DATA #(parameter ICACHE_TAG_HIGH = 16 ,
                           ICACHE_TAG_LOW=6 ,
                           ICACHE_IC_DEPTH=1024
                                        )
     (
      input logic free_clk,
      input logic clk,
      input logic rst_l,
      input logic clk_override,

      input logic [31:3]                 ic_rw_addr_full,
      input logic [ICACHE_TAG_HIGH-1:2]  ic_rw_addr,
      input logic [3:0]                  ic_wr_en,
      input logic                        ic_rd_en,  // Read enable
`ifdef RV_ICACHE_ECC
      input  logic [83:0]               ic_wr_data,         // Data to fill to the Icache. With ECC
      output logic [167:0]              ic_rd_data ,        // Data read from Icache. 2x64bits + parity bits. F2 stage. With ECC
      input  logic [41:0]               ic_debug_wr_data,   // Debug wr cache.
`else
      input  logic [67:0]               ic_wr_data,         // Data to fill to the Icache. With Parity
      output logic [135:0]              ic_rd_data ,        // Data read from Icache. 2x64bits + parity bits. F2 stage. With Parity
      input  logic [33:0]               ic_debug_wr_data,   // Debug wr cache.
`endif


      input logic [ICACHE_TAG_HIGH-1:2]  ic_debug_addr,      // Read/Write addresss to the Icache.
      input logic                        ic_debug_rd_en,     // Icache debug rd
      input logic                        ic_debug_wr_en,     // Icache debug wr
      input logic                        ic_debug_tag_array, // Debug tag array
      input logic [3:0]                  ic_debug_way,       // Debug way. Rd or Wr.
      input logic [127:0]                ic_premux_data,     // Premux data to be muxed with each way of the Icache.
      input logic                        ic_sel_premux_data, // Select the pre_muxed data

      input logic [3:0]          ic_rd_hit,

      input  logic               scan_mode

      ) ;

   logic [5:4]             ic_rw_addr_ff;


   logic [3:0][3:0]       ic_b_sb_wren, ic_bank_way_clken, ic_bank_way_clk;    // way, bank

   logic                   ic_debug_sel_sb0 ;
   logic                   ic_debug_sel_sb1 ;
   logic                   ic_debug_sel_sb2 ;
   logic                   ic_debug_sel_sb3 ;


`ifdef RV_ICACHE_ECC
   logic [3:0] [167:0]     bank_set_dout;
   logic [3:0][167:0]      wb_dout ; //
   logic [3:0][41:0]       ic_sb_wr_data;
`else
   logic [3:0] [135:0]     bank_set_dout;
   logic [3:0] [135:0]     wb_dout ; // bank , way , size
   logic [3:0] [33:0]      ic_sb_wr_data;
`endif

   logic                   ic_b_rden;
   logic [3:0]             ic_debug_rd_way_en;   // debug wr_way
   logic [3:0]             ic_debug_rd_way_en_ff;   // debug wr_way
   logic [3:0]             ic_debug_wr_way_en;   // debug wr_way
   logic [ICACHE_TAG_HIGH-1:4]  ic_rw_addr_q;

   assign  ic_debug_rd_way_en[3:0] =  {4{ic_debug_rd_en & ~ic_debug_tag_array}} & ic_debug_way[3:0] ;
   assign  ic_debug_wr_way_en[3:0] =  {4{ic_debug_wr_en & ~ic_debug_tag_array}} & ic_debug_way[3:0] ;

   assign  ic_b_sb_wren[0][3:0]  = (ic_wr_en[3:0]           & {4{~ic_rw_addr[3]}} ) |
                                   (ic_debug_wr_way_en[3:0] & {4{ic_debug_addr[3:2] == 2'b00}}) ;
   assign  ic_b_sb_wren[1][3:0]  = (ic_wr_en[3:0]           & {4{~ic_rw_addr[3]}} ) |
                                   (ic_debug_wr_way_en[3:0] & {4{ic_debug_addr[3:2] == 2'b01}}) ;
   assign  ic_b_sb_wren[2][3:0]  = (ic_wr_en[3:0]           & {4{ic_rw_addr[3]}} ) |
                                   (ic_debug_wr_way_en[3:0] & {4{ic_debug_addr[3:2] == 2'b10}}) ;
   assign  ic_b_sb_wren[3][3:0]  = (ic_wr_en[3:0]           & {4{ic_rw_addr[3]}} ) |
                                   (ic_debug_wr_way_en[3:0] & {4{ic_debug_addr[3:2] == 2'b11}}) ;

   assign  ic_debug_sel_sb0       =  (ic_debug_addr[3:2] == 2'b00 ) ;
   assign  ic_debug_sel_sb1       =  (ic_debug_addr[3:2] == 2'b01 ) ;
   assign  ic_debug_sel_sb2       =  (ic_debug_addr[3:2] == 2'b10 ) ;
   assign  ic_debug_sel_sb3       =  (ic_debug_addr[3:2] == 2'b11 ) ;


`ifdef RV_ICACHE_ECC

   assign  ic_sb_wr_data[0][41:0]   =  (ic_debug_sel_sb0 & ic_debug_wr_en) ? {ic_debug_wr_data[41:0]} :
                                                                             ic_wr_data[41:0] ;
   assign  ic_sb_wr_data[1][41:0]   =  (ic_debug_sel_sb1 & ic_debug_wr_en) ? {ic_debug_wr_data[41:0]} :
                                                                             ic_wr_data[83:42] ;
   assign  ic_sb_wr_data[2][41:0]   =  (ic_debug_sel_sb2 & ic_debug_wr_en) ? {ic_debug_wr_data[41:0]} :
                                                                             ic_wr_data[41:0] ;
   assign  ic_sb_wr_data[3][41:0]   =  (ic_debug_sel_sb3 & ic_debug_wr_en) ? {ic_debug_wr_data[41:0]} :
                                                                             ic_wr_data[83:42] ;
`else
   assign  ic_sb_wr_data[0][33:0]   =  (ic_debug_sel_sb0 & ic_debug_wr_en) ? ic_debug_wr_data[33:0] :
                                                                             ic_wr_data[33:0] ;
   assign  ic_sb_wr_data[1][33:0]   =  (ic_debug_sel_sb1 & ic_debug_wr_en) ? ic_debug_wr_data[33:0] :
                                                                             ic_wr_data[67:34] ;
   assign  ic_sb_wr_data[2][33:0]   =  (ic_debug_sel_sb2 & ic_debug_wr_en) ? ic_debug_wr_data[33:0] :
                                                                             ic_wr_data[33:0] ;
   assign  ic_sb_wr_data[3][33:0]   =  (ic_debug_sel_sb3 & ic_debug_wr_en) ? ic_debug_wr_data[33:0] :
                                                                             ic_wr_data[67:34] ;
`endif


// bank read enables

   assign  ic_b_rden       = (ic_rd_en   | ic_debug_rd_en );

   logic [3:0] ic_bank_read;
   logic [3:0] ic_bank_read_ff;
   assign ic_bank_read[0] = (ic_b_rden) & (~|ic_rw_addr[3:2] | ic_debug_rd_en);
   assign ic_bank_read[1] = (ic_b_rden) & (~ic_rw_addr[3] | ic_debug_rd_en);
   assign ic_bank_read[2] = (ic_b_rden) & (~&ic_rw_addr[3:2] | ic_debug_rd_en);
   assign ic_bank_read[3] = (ic_b_rden) | ic_debug_rd_en;

   assign ic_rw_addr_q[ICACHE_TAG_HIGH-1:4] = (ic_debug_rd_en | ic_debug_wr_en) ?
                                                ic_debug_addr[ICACHE_TAG_HIGH-1:4] :
                                                ic_rw_addr[ICACHE_TAG_HIGH-1:4] ;

   logic ic_debug_rd_en_ff;

   rvdff #(2) adr_ff (.*,
                    .clk(free_clk),
                    .din ({ic_rw_addr_q[5:4]}),
                    .dout({ic_rw_addr_ff[5:4]}));

   rvdff #(4) bank_adr_ff (.*,
                    .clk(free_clk),
                    .din (ic_bank_read[3:0]),
                    .dout(ic_bank_read_ff[3:0]));

   rvdff #(5) debug_rd_wy_ff (.*,
                    .clk(free_clk),
                    .din ({ic_debug_rd_way_en[3:0], ic_debug_rd_en}),
                    .dout({ic_debug_rd_way_en_ff[3:0], ic_debug_rd_en_ff}));

localparam NUM_WAYS=4 ;
localparam NUM_SUBBANKS=4 ;


     for (genvar i=0; i<NUM_WAYS; i++) begin: WAYS


        for (genvar k=0; k<NUM_SUBBANKS; k++) begin: SUBBANKS   // 16B subbank

           // way3-bank3, way3-bank2, ... way0-bank0
           assign  ic_bank_way_clken[i][k]   = ic_bank_read[k] |  ic_b_sb_wren[k][i];

           rvoclkhdr bank_way_bank_c1_cgc  ( .en(ic_bank_way_clken[i][k] | clk_override), .l1clk(ic_bank_way_clk[i][k]), .* );

        `ifdef RV_ICACHE_ECC
         `RV_ICACHE_DATA_CELL  ic_bank_sb_way_data (
                                     .CLK(ic_bank_way_clk[i][k]),
                                     .WE (ic_b_sb_wren[k][i]),
                                     .D  (ic_sb_wr_data[k][41:0]),
                                     .ADR(ic_rw_addr_q[ICACHE_TAG_HIGH-1:4]),
                                     .Q  (wb_dout[i][(k+1)*42-1:k*42])
                                    );
        `else
         `RV_ICACHE_DATA_CELL  ic_bank_sb_way_data (
                                     .CLK(ic_bank_way_clk[i][k]),
                                     .WE (ic_b_sb_wren[k][i]),
                                     .D  (ic_sb_wr_data[k][33:0]),
                                     .ADR(ic_rw_addr_q[ICACHE_TAG_HIGH-1:4]),
                                     .Q  (wb_dout[i][(k+1)*34-1:k*34])
                                    );
        `endif
        end // block: SUBBANKS

      end


   logic [3:0] ic_rd_hit_q;
   assign ic_rd_hit_q[3:0] = ic_debug_rd_en_ff ? ic_debug_rd_way_en_ff[3:0] : ic_rd_hit[3:0] ;

   // set mux
`ifdef RV_ICACHE_ECC
   logic [167:0] ic_premux_data_ext;
   logic [3:0] [167:0] wb_dout_way;
   logic [3:0] [167:0] wb_dout_way_with_premux;

   assign ic_premux_data_ext[167:0] =  {10'b0,ic_premux_data[127:96],10'b0,ic_premux_data[95:64] ,10'b0,ic_premux_data[63:32],10'b0,ic_premux_data[31:0]};
   assign wb_dout_way[0][167:0]       = wb_dout[0][167:0] & {  {42{ic_bank_read_ff[3]}} ,  {42{ic_bank_read_ff[2]}}  ,  {42{ic_bank_read_ff[1]}}  ,  {42{ic_bank_read_ff[0]}} };
   assign wb_dout_way[1][167:0]       = wb_dout[1][167:0] & {  {42{ic_bank_read_ff[3]}} ,  {42{ic_bank_read_ff[2]}}  ,  {42{ic_bank_read_ff[1]}}  ,  {42{ic_bank_read_ff[0]}} };
   assign wb_dout_way[2][167:0]       = wb_dout[2][167:0] & {  {42{ic_bank_read_ff[3]}} ,  {42{ic_bank_read_ff[2]}}  ,  {42{ic_bank_read_ff[1]}}  ,  {42{ic_bank_read_ff[0]}} };
   assign wb_dout_way[3][167:0]       = wb_dout[3][167:0] & {  {42{ic_bank_read_ff[3]}} ,  {42{ic_bank_read_ff[2]}}  ,  {42{ic_bank_read_ff[1]}}  ,  {42{ic_bank_read_ff[0]}} };


   assign wb_dout_way_with_premux[0][167:0]  =  ic_sel_premux_data ? ic_premux_data_ext[167:0] : wb_dout_way[0][167:0] ;
   assign wb_dout_way_with_premux[1][167:0]  =  ic_sel_premux_data ? ic_premux_data_ext[167:0] : wb_dout_way[1][167:0] ;
   assign wb_dout_way_with_premux[2][167:0]  =  ic_sel_premux_data ? ic_premux_data_ext[167:0] : wb_dout_way[2][167:0] ;
   assign wb_dout_way_with_premux[3][167:0]  =  ic_sel_premux_data ? ic_premux_data_ext[167:0] : wb_dout_way[3][167:0] ;

   assign ic_rd_data[167:0]       = ({168{ic_rd_hit_q[0] | ic_sel_premux_data}} &  wb_dout_way_with_premux[0][167:0]) |
                                    ({168{ic_rd_hit_q[1] | ic_sel_premux_data}} &  wb_dout_way_with_premux[1][167:0]) |
                                    ({168{ic_rd_hit_q[2] | ic_sel_premux_data}} &  wb_dout_way_with_premux[2][167:0]) |
                                    ({168{ic_rd_hit_q[3] | ic_sel_premux_data}} &  wb_dout_way_with_premux[3][167:0]) ;

`else
   logic       [135:0] ic_premux_data_ext;
   logic [3:0] [135:0] wb_dout_way;
   logic [3:0] [135:0] wb_dout_way_with_premux;

   assign ic_premux_data_ext[135:0]   = {2'b0,ic_premux_data[127:96],2'b0,ic_premux_data[95:64] ,2'b0,ic_premux_data[63:32],2'b0,ic_premux_data[31:0]};
   assign wb_dout_way[0][135:0]       = wb_dout[0][135:0] &  {  {34{ic_bank_read_ff[3]}} ,  {34{ic_bank_read_ff[2]}}  ,  {34{ic_bank_read_ff[1]}}  ,  {34{ic_bank_read_ff[0]}} };
   assign wb_dout_way[1][135:0]       = wb_dout[1][135:0] &  {  {34{ic_bank_read_ff[3]}} ,  {34{ic_bank_read_ff[2]}}  ,  {34{ic_bank_read_ff[1]}}  ,  {34{ic_bank_read_ff[0]}} };
   assign wb_dout_way[2][135:0]       = wb_dout[2][135:0] &  {  {34{ic_bank_read_ff[3]}} ,  {34{ic_bank_read_ff[2]}}  ,  {34{ic_bank_read_ff[1]}}  ,  {34{ic_bank_read_ff[0]}} };
   assign wb_dout_way[3][135:0]       = wb_dout[3][135:0] &  {  {34{ic_bank_read_ff[3]}} ,  {34{ic_bank_read_ff[2]}}  ,  {34{ic_bank_read_ff[1]}}  ,  {34{ic_bank_read_ff[0]}} };

   assign wb_dout_way_with_premux[0][135:0]  =  ic_sel_premux_data ? ic_premux_data_ext[135:0] : wb_dout_way[0][135:0] ;
   assign wb_dout_way_with_premux[1][135:0]  =  ic_sel_premux_data ? ic_premux_data_ext[135:0] : wb_dout_way[1][135:0] ;
   assign wb_dout_way_with_premux[2][135:0]  =  ic_sel_premux_data ? ic_premux_data_ext[135:0] : wb_dout_way[2][135:0] ;
   assign wb_dout_way_with_premux[3][135:0]  =  ic_sel_premux_data ? ic_premux_data_ext[135:0] : wb_dout_way[3][135:0] ;

   assign ic_rd_data[135:0]       = ({136{ic_rd_hit_q[0] | ic_sel_premux_data}} &  wb_dout_way_with_premux[0][135:0]) |
                                    ({136{ic_rd_hit_q[1] | ic_sel_premux_data}} &  wb_dout_way_with_premux[1][135:0]) |
                                    ({136{ic_rd_hit_q[2] | ic_sel_premux_data}} &  wb_dout_way_with_premux[2][135:0]) |
                                    ({136{ic_rd_hit_q[3] | ic_sel_premux_data}} &  wb_dout_way_with_premux[3][135:0]) ;

`endif

 endmodule


/////////////////////////////////////////////////
////// ICACHE TAG MODULE     ////////////////////
/////////////////////////////////////////////////
module IC_TAG #(parameter ICACHE_TAG_HIGH = 16 ,
                          ICACHE_TAG_LOW=6 ,
                          ICACHE_TAG_DEPTH=1024
                                        )
     (
      input logic free_clk,
      input logic clk,
      input logic rst_l,
      input logic clk_override,
      input logic dec_tlu_core_ecc_disable,

      input logic [31:3]  ic_rw_addr,

      input logic [3:0]   ic_wr_en,  // way
      input logic [3:0]   ic_tag_valid,
      input logic         ic_rd_en,

      input logic [ICACHE_TAG_HIGH-1:2]  ic_debug_addr,      // Read/Write addresss to the Icache.
      input logic                        ic_debug_rd_en,     // Icache debug rd
      input logic                        ic_debug_wr_en,     // Icache debug wr
      input logic                        ic_debug_tag_array, // Debug tag array
      input logic [3:0]                  ic_debug_way,       // Debug way. Rd or Wr.

`ifdef RV_ICACHE_RANDOM_PLACEMENT
			input logic [9:0]		real_tag,
`endif


`ifdef RV_ICACHE_ECC
      output logic [24:0]  ictag_debug_rd_data,
      input  logic [41:0]  ic_debug_wr_data,   // Debug wr cache.
`else
      output logic [20:0]  ictag_debug_rd_data,
      input  logic [33:0]  ic_debug_wr_data,   // Debug wr cache.
`endif
      output logic [3:0]   ic_rd_hit,
      output logic         ic_tag_perr,
      input  logic         scan_mode

      ) ;

`ifdef RV_ICACHE_ECC
   logic [3:0] [24:0] ic_tag_data_raw;
   logic [3:0] [37:ICACHE_TAG_HIGH] w_tout;
   logic [24:0] ic_tag_wr_data ;
   logic [3:0] [31:0] ic_tag_corrected_data_unc;
   logic [3:0] [06:0] ic_tag_corrected_ecc_unc;
   logic [3:0]        ic_tag_single_ecc_error;
   logic [3:0]        ic_tag_double_ecc_error;
`else
   logic [3:0] [20:0] ic_tag_data_raw;
   logic [3:0] [32:ICACHE_TAG_HIGH] w_tout;
   logic [20:0] ic_tag_wr_data ;
`endif

   logic [3:0]  ic_tag_way_perr ;
   logic [3:0]  ic_debug_rd_way_en ;
   logic [3:0]  ic_debug_rd_way_en_ff ;

   logic [ICACHE_TAG_HIGH-1:6]  ic_rw_addr_q;
   logic [31:4]         ic_rw_addr_ff;
   logic [3:0]          ic_tag_wren   ; // way
   logic [3:0]          ic_tag_wren_q   ; // way
   logic [3:0]          ic_tag_clk ;
   logic [3:0]          ic_tag_clken ;
   logic [3:0]          ic_debug_wr_way_en;   // debug wr_way
	 logic [3:0] 				  ic_tag_rprr;

	`ifdef RV_ICACHE_RANDOM_PLACEMENT
   rvdff #(10) rt_ff (.*,
                    .clk(free_clk),
                    .din (real_tag),
                    .dout(real_tag_ff));
   logic [3:0] [9:0] w_real_tag;
	 logic [9:0] real_tag_ff;
	 `endif
   assign  ic_tag_wren [3:0]  = ic_wr_en[3:0] & {4{ic_rw_addr[5:3] == 3'b111}} ;
   assign  ic_tag_clken[3:0]  = {4{ic_rd_en | clk_override}} | ic_wr_en[3:0] | ic_debug_wr_way_en[3:0] | ic_debug_rd_way_en[3:0];

   rvdff #(32-ICACHE_TAG_HIGH) adr_ff (.*,
                    .clk(free_clk),
                    .din ({ic_rw_addr[31:ICACHE_TAG_HIGH]}),
                    .dout({ic_rw_addr_ff[31:ICACHE_TAG_HIGH]}));


   localparam TOP_BITS = 21+ICACHE_TAG_HIGH-33 ;
   localparam NUM_WAYS=4 ;
   // tags



   assign  ic_debug_rd_way_en[3:0] =  {4{ic_debug_rd_en & ic_debug_tag_array}} & ic_debug_way[3:0] ;
   assign  ic_debug_wr_way_en[3:0] =  {4{ic_debug_wr_en & ic_debug_tag_array}} & ic_debug_way[3:0] ;

   assign  ic_tag_wren_q[3:0]  =  ic_tag_wren[3:0]          |
                                  ic_debug_wr_way_en[3:0]   ;

if (ICACHE_TAG_HIGH == 12) begin: SMALLEST
 `ifdef RV_ICACHE_ECC
     logic [6:0] ic_tag_ecc;
           rvecc_encode  tag_ecc_encode (
                                  .din    ({{ICACHE_TAG_HIGH{1'b0}}, ic_rw_addr[31:ICACHE_TAG_HIGH]}),
                                  .ecc_out({ ic_tag_ecc[6:0]}));

   assign  ic_tag_wr_data[24:0] = (ic_debug_wr_en & ic_debug_tag_array) ?
                                  {ic_debug_wr_data[36:32], ic_debug_wr_data[31:12]} :
                                  {ic_tag_ecc[4:0], ic_rw_addr[31:ICACHE_TAG_HIGH]} ;
 `else
   logic   ic_tag_parity ;
           rveven_paritygen #(32-ICACHE_TAG_HIGH) pargen  (.data_in   (ic_rw_addr[31:ICACHE_TAG_HIGH]),
                                                 .parity_out(ic_tag_parity));

   assign  ic_tag_wr_data[20:0] = (ic_debug_wr_en & ic_debug_tag_array) ?
                                  {ic_debug_wr_data[32], ic_debug_wr_data[31:12]} :
                                  {ic_tag_parity, ic_rw_addr[31:ICACHE_TAG_HIGH]} ;
 `endif
end else begin: OTHERS
 `ifdef RV_ICACHE_ECC
   logic [6:0] ic_tag_ecc;
           rvecc_encode  tag_ecc_encode (
                                  .din    ({{ICACHE_TAG_HIGH{1'b0}}, ic_rw_addr[31:ICACHE_TAG_HIGH]}),
                                  .ecc_out({ ic_tag_ecc[6:0]}));

   assign  ic_tag_wr_data[24:0] = (ic_debug_wr_en & ic_debug_tag_array) ?
                                  {ic_debug_wr_data[36:32], ic_debug_wr_data[31:12]} :
                                  {ic_tag_ecc[4:0], {TOP_BITS{1'b0}},ic_rw_addr[31:ICACHE_TAG_HIGH]} ;

 `else
   logic   ic_tag_parity ;
           rveven_paritygen #(32-ICACHE_TAG_HIGH) pargen  (.data_in   (ic_rw_addr[31:ICACHE_TAG_HIGH]),
                                                 .parity_out(ic_tag_parity));
   assign  ic_tag_wr_data[20:0] = (ic_debug_wr_en & ic_debug_tag_array) ?
                                  {ic_debug_wr_data[32], ic_debug_wr_data[31:12]} :
                                  {ic_tag_parity, {TOP_BITS{1'b0}},ic_rw_addr[31:ICACHE_TAG_HIGH]} ;
 `endif
end
    

    assign ic_rw_addr_q[ICACHE_TAG_HIGH-1:6] = (ic_debug_rd_en | ic_debug_wr_en) ?
                                                ic_debug_addr[ICACHE_TAG_HIGH-1:6] :
                                                ic_rw_addr[ICACHE_TAG_HIGH-1:6] ;
    


   rvdff #(4) tag_rd_wy_ff (.*,
                    .clk(free_clk),
                    .din ({ic_debug_rd_way_en[3:0]}),
                    .dout({ic_debug_rd_way_en_ff[3:0]}));




   for (genvar i=0; i<NUM_WAYS; i++) begin: WAYS

      rvoclkhdr ic_tag_c1_cgc  ( .en(ic_tag_clken[i]), .l1clk(ic_tag_clk[i]), .* );

     if (ICACHE_TAG_DEPTH == 64 ) begin : ICACHE_SZ_16
      `ifdef RV_ICACHE_ECC
         ram_64x25  ic_way_tag (
                                     .CLK(ic_tag_clk[i]),
                                     .WE (ic_tag_wren_q[i]),
                                     .D  (ic_tag_wr_data[24:0]),
                                     .ADR(ic_rw_addr_q[ICACHE_TAG_HIGH-1:ICACHE_TAG_LOW]),
                                     .Q  (ic_tag_data_raw[i][24:0])
                                    );


         assign w_tout[i][31:ICACHE_TAG_HIGH] = ic_tag_data_raw[i][31-ICACHE_TAG_HIGH:0] ;
         assign w_tout[i][36:32]              = ic_tag_data_raw[i][24:20] ;

         rvecc_decode  ecc_decode (
                           .en(~dec_tlu_core_ecc_disable),
                           .sed_ded ( 1'b1 ),    // 1 : means only detection
                           .din({12'b0,ic_tag_data_raw[i][19:0]}),
                           .ecc_in({2'b0, ic_tag_data_raw[i][24:20]}),
                           .dout(ic_tag_corrected_data_unc[i][31:0]),
                           .ecc_out(ic_tag_corrected_ecc_unc[i][6:0]),
                           .single_ecc_error(ic_tag_single_ecc_error[i]),
                           .double_ecc_error(ic_tag_double_ecc_error[i]));

          assign ic_tag_way_perr[i]= ic_tag_single_ecc_error[i] | ic_tag_double_ecc_error[i]  ;
      `else
         ram_64x21  ic_way_tag (
                                     .CLK(ic_tag_clk[i]),
                                     .WE (ic_tag_wren_q[i]),
                                     .D  (ic_tag_wr_data[20:0]),
                                     .ADR(ic_rw_addr_q[ICACHE_TAG_HIGH-1:ICACHE_TAG_LOW]),
                                     .Q  (ic_tag_data_raw[i][20:0])
                                    );

         assign w_tout[i][31:ICACHE_TAG_HIGH] = ic_tag_data_raw[i][31-ICACHE_TAG_HIGH:0] ;
         assign w_tout[i][32]                 = ic_tag_data_raw[i][20] ;

         rveven_paritycheck #(32-ICACHE_TAG_HIGH) parcheck(.data_in   (w_tout[i][31:ICACHE_TAG_HIGH]),
                                                   .parity_in (w_tout[i][32]),
                                                   .parity_err(ic_tag_way_perr[i]));
      `endif

   end // block: ICACHE_SZ_16

   else begin : tag_not_64
    `ifdef RV_ICACHE_ECC
     `RV_ICACHE_TAG_CELL  ic_way_tag (
                                     .CLK(ic_tag_clk[i]),
                                     .WE (ic_tag_wren_q[i]),
                                     .D  (ic_tag_wr_data[24:0]),
                                     .ADR(ic_rw_addr_q[ICACHE_TAG_HIGH-1:ICACHE_TAG_LOW]),
                                     .Q  (ic_tag_data_raw[i][24:0])
                                    );

         assign w_tout[i][31:ICACHE_TAG_HIGH] = ic_tag_data_raw[i][31-ICACHE_TAG_HIGH:0] ;
         assign w_tout[i][36:32]              = ic_tag_data_raw[i][24:20] ;

         rvecc_decode  ecc_decode (
                           .en(~dec_tlu_core_ecc_disable),
                           .sed_ded ( 1'b1 ), // 1 : if only need detection
                           .din({12'b0,ic_tag_data_raw[i][19:0]}),
                           .ecc_in({2'b0, ic_tag_data_raw[i][24:20]}),
                           .dout(ic_tag_corrected_data_unc[i][31:0]),
                           .ecc_out(ic_tag_corrected_ecc_unc[i][6:0]),
                           .single_ecc_error(ic_tag_single_ecc_error[i]),
                           .double_ecc_error(ic_tag_double_ecc_error[i]));

          assign ic_tag_way_perr[i]= ic_tag_single_ecc_error[i] | ic_tag_double_ecc_error[i]  ;

     `else
        `RV_ICACHE_TAG_CELL  ic_way_tag (
                                     .CLK(ic_tag_clk[i]),
                                     .WE (ic_tag_wren_q[i]),
                                     .D  (ic_tag_wr_data[20:0]),
                                     .ADR(ic_rw_addr_q[ICACHE_TAG_HIGH-1:ICACHE_TAG_LOW]),
                                     .Q  ({ic_tag_data_raw[i][20:0]})
                                    );

         assign w_tout[i][31:ICACHE_TAG_HIGH] = ic_tag_data_raw[i][31-ICACHE_TAG_HIGH:0] ;
         assign w_tout[i][32]                 = ic_tag_data_raw[i][20] ;

       rveven_paritycheck #(32-ICACHE_TAG_HIGH) parcheck(.data_in   (w_tout[i][31:ICACHE_TAG_HIGH]),
                                                   .parity_in (w_tout[i][32]),
                                                   .parity_err(ic_tag_way_perr[i]));

      `endif
   end // block: tag_not_64
	 `ifdef RV_ICACHE_RANDOM_PLACEMENT
	 		`RV_ICACHE_RPRR_RAM ic_rprr (
   															.CLK(ic_tag_clk[i]),
                                .WE (ic_tag_wren_q[i]),
                                .D  (real_tag[9:0]),
                                .ADR(ic_rw_addr_q[ICACHE_TAG_HIGH-1:ICACHE_TAG_LOW]),
                                .Q  (w_real_tag[i][9:0])
																);
			assign ic_tag_rprr[0] = w_real_tag[0][9:0] == real_tag_ff[9:0] ? 1'b1 : 1'b0;
			assign ic_tag_rprr[1] = w_real_tag[1][9:0] == real_tag_ff[9:0] ? 1'b1 : 1'b0;
			assign ic_tag_rprr[2] = w_real_tag[2][9:0] == real_tag_ff[9:0] ? 1'b1 : 1'b0;
			assign ic_tag_rprr[3] = w_real_tag[3][9:0] == real_tag_ff[9:0] ? 1'b1 : 1'b0;
`else
			assign ic_tag_rprr[0] = 1'b1;
			assign ic_tag_rprr[1] = 1'b1;
			assign ic_tag_rprr[2] = 1'b1;
			assign ic_tag_rprr[3] = 1'b1;
`endif
end // block: WAYS


`ifdef RV_ICACHE_ECC
   assign ictag_debug_rd_data[24:0] =  ({25{ic_debug_rd_way_en_ff[0]}} &  ic_tag_data_raw[0] ) |
                                       ({25{ic_debug_rd_way_en_ff[1]}} &  ic_tag_data_raw[1] ) |
                                       ({25{ic_debug_rd_way_en_ff[2]}} &  ic_tag_data_raw[2] ) |
                                       ({25{ic_debug_rd_way_en_ff[3]}} &  ic_tag_data_raw[3] ) ;

`else
   assign ictag_debug_rd_data[20:0] =  ({21{ic_debug_rd_way_en_ff[0]}} &  ic_tag_data_raw[0] ) |
                                       ({21{ic_debug_rd_way_en_ff[1]}} &  ic_tag_data_raw[1] ) |
                                       ({21{ic_debug_rd_way_en_ff[2]}} &  ic_tag_data_raw[2] ) |
                                       ({21{ic_debug_rd_way_en_ff[3]}} &  ic_tag_data_raw[3] ) ;

`endif


   assign ic_rd_hit[0] = (w_tout[0][31:ICACHE_TAG_HIGH] == ic_rw_addr_ff[31:ICACHE_TAG_HIGH]) & ic_tag_valid[0] & ic_tag_rprr[0]; 
   assign ic_rd_hit[1] = (w_tout[1][31:ICACHE_TAG_HIGH] == ic_rw_addr_ff[31:ICACHE_TAG_HIGH]) & ic_tag_valid[1] & ic_tag_rprr[1];
   assign ic_rd_hit[2] = (w_tout[2][31:ICACHE_TAG_HIGH] == ic_rw_addr_ff[31:ICACHE_TAG_HIGH]) & ic_tag_valid[2] & ic_tag_rprr[2];
   assign ic_rd_hit[3] = (w_tout[3][31:ICACHE_TAG_HIGH] == ic_rw_addr_ff[31:ICACHE_TAG_HIGH]) & ic_tag_valid[3] & ic_tag_rprr[3];

   assign  ic_tag_perr  = | (ic_tag_way_perr[3:0] & ic_tag_valid[3:0] ) ;
endmodule



module five_rotator #(
				parameter integer SIZE=32
				)
				(
				input  logic[SIZE-1:0] num,
				input  logic[4:0] shift,
				output logic[SIZE-1:0] rotated
				);

		logic[SIZE-1:0] s1, s2, s3, s4, s5;
		always_comb begin
			s1 = shift[0] ? {num[SIZE-2:0], num[SIZE-1       ]}  : num;
			s2 = shift[1] ? {s1 [SIZE-3:0], s1 [SIZE-1:SIZE-2]}  : s1;
			s3 = shift[2] ? {s2 [SIZE-5:0], s2 [SIZE-1:SIZE-4]}  : s2;
			s4 = shift[3] ? {s3 [SIZE-9:0], s3 [SIZE-1:SIZE-8]}  : s3;
			s5 = shift[4] ? {s4 [SIZE-17:0],s4 [SIZE-1:SIZE-16]} : s4;
		end
	
		assign rotated = s5;
endmodule

module hash_same_size #(
        parameter integer SIZE = 32
    )
    (
        input  logic clk_i,
				input  logic randomize_i,
        input  logic [SIZE-1 : 0] addr_i ,
        output logic [SIZE-1 : 0] line_index_o 
    );

//***Interal logic generated by compiler***  
    logic [31 : 0] prng_out, random_number_w;
		localparam SIZE2 = SIZE*2;
		localparam SIZE4 = SIZE*4;
		localparam SIZE8 = SIZE*8;
    logic[63:0] lfsr_seed;
`ifndef SYNTHESIS
	 initial begin
	    longint hash_seed;
	    if($value$plusargs("btb_seed=%d", hash_seed)) begin
				lfsr_seed = hash_seed;
				random_number_w = hash_seed[31:0];
//				prng_out = hash_seed[31:0];
			end else begin
				lfsr_seed = '0;
			end
	 end
`else
    assign lfsr_seed = '0;
`endif
    reg [SIZE-1:0] rotate_0;
    reg [SIZE-1:0] rotate_1;
    reg [SIZE-1:0] rotate_2;
    reg [SIZE-1:0] rotate_3;
    reg [SIZE-1:0] rotate_4;
    reg [SIZE-1:0] rotate_5;
    reg [SIZE-1:0] rotate_6;
    reg [SIZE-1:0] rotate_7;
    wire [SIZE8-1:0] combined;
    wire [SIZE4-1:0] output_xor_1;
    wire [SIZE2-1:0] output_xor_2;
    wire [SIZE  -1:0] output_xor_3;
    
    five_rotator #(SIZE) r1 (.num(addr_i), 										.shift(random_number_w[4:0]), 	.rotated(rotate_0));
    five_rotator #(SIZE) r2 (.num(addr_i), 										.shift(random_number_w[9:5]), 	.rotated(rotate_1));
    five_rotator #(SIZE) r3 (.num(addr_i), 										.shift(random_number_w[14:10]),	.rotated(rotate_2));
    five_rotator #(SIZE) r4 (.num(addr_i), 										.shift(random_number_w[19:15]),	.rotated(rotate_3));
    five_rotator #(SIZE) r5 (.num(random_number_w[SIZE-1:0]), .shift(addr_i[5:1]), 						.rotated(rotate_4));
    five_rotator #(SIZE) r6 (.num(random_number_w[SIZE-1:0]), .shift(addr_i[10:6]), 					.rotated(rotate_5));
    five_rotator #(SIZE) r7 (.num(random_number_w[SIZE-1:0]), .shift(addr_i[15:11]), 					.rotated(rotate_6));
    five_rotator #(SIZE) r8 (.num(random_number_w[SIZE-1:0]), .shift(addr_i[20:16]), 					.rotated(rotate_7));

		assign combined = {rotate_0[SIZE-1:0], rotate_7[SIZE-1:0], rotate_1[SIZE-1:0], rotate_6[SIZE-1:0], rotate_2[SIZE-1:0], rotate_5[SIZE-1:0], rotate_3[SIZE-1:0], rotate_4[SIZE-1:0]};
    assign output_xor_1 = combined[SIZE8-1:SIZE4] ^ combined[SIZE4-1:0];
    assign output_xor_2 = output_xor_1[SIZE4-1:SIZE2] ^ output_xor_1[SIZE2-1:0];
    assign output_xor_3 = output_xor_2[SIZE2-1:SIZE] ^ output_xor_2[SIZE-1:0];

    assign line_index_o = output_xor_3[SIZE-1:0];

    
endmodule 

module hash_to_6 #(
        parameter integer WORD_SIZE = 32
    )
    (
        input  logic clk_i,
				input  logic rst_l,
				input  logic randomize_i,
        input  logic [25 : 0] addr_i ,
        output logic [WORD_SIZE-1 : 0] line_index_o 
    );

//***Interal logic generated by compiler***  
    logic [31 : 0] prng_out, random_number_w;

    logic[63:0] lfsr_seed;
`ifndef SYNTHESIS
	 initial begin
	    longint hash_seed;
	    if($value$plusargs("hash_seed=%d", hash_seed)) begin
				lfsr_seed = hash_seed;
				random_number_w = hash_seed[31:0];
				prng_out = hash_seed[31:0];
			end else begin
				lfsr_seed = '0;
			end
	 end
`else
    assign lfsr_seed = '0;
`endif
//	logic randomize_reset_ff;
//	rvdff #(1) rrff(.*, .clk(clk_i), .din(!rst_l&randomize_i), .dout(randomize_reset_ff));
   lfsr_prng #(32) lfsr (.*, .clk(clk_i), .output_number_o(prng_out), .seed_i(lfsr_seed));
	 
   rvdffs #(32) hash_key (.*,.clk(clk_i), .din (prng_out), .dout(random_number_w), .en(randomize_i));

//***Dumped Internal logic***
    reg [25:0] rotate_0;
    reg [25:0] rotate_1;
    reg [25:0] rotate_2;
    reg [25:0] rotate_3;
    reg [31:0] rotate_4;
    reg [31:0] rotate_5;
    reg [31:0] rotate_6;
    wire [191:0] combined;
    wire [95:0] output_xor_1;
    wire [47:0] output_xor_2;
    wire [23:0] output_xor_3;
    wire [11:0] output_xor_4;
    wire [5:0] output_xor_5;
    
    five_rotator #(26) r1 (.num(addr_i), .shift(random_number_w[4:0]), 	 .rotated(rotate_0));
    five_rotator #(26) r2 (.num(addr_i), .shift(random_number_w[9:5]), 	 .rotated(rotate_1));
    five_rotator #(26) r3 (.num(addr_i), .shift(random_number_w[14:10]), .rotated(rotate_2));
    five_rotator #(26) r4 (.num(addr_i), .shift(random_number_w[19:15]), .rotated(rotate_3));
    five_rotator #(32) r5 (.num(random_number_w), .shift(addr_i[4:0]),   .rotated(rotate_4));
    five_rotator #(32) r6 (.num(random_number_w), .shift(addr_i[9:5]),   .rotated(rotate_5));
    five_rotator #(32) r7 (.num(random_number_w), .shift(addr_i[14:10]), .rotated(rotate_6));
		
		assign combined = {rotate_0, rotate_5, rotate_2, rotate_3[17:0], rotate_4, rotate_1, rotate_6};
    assign output_xor_1 = combined[191:96] 		^ combined[95:0];
    assign output_xor_2 = output_xor_1[95:48] ^ output_xor_1[47:0];
    assign output_xor_3 = output_xor_2[47:24] ^ output_xor_2[23:0];
    assign output_xor_4 = output_xor_3[23:12] ^ output_xor_3[11:0];
    assign output_xor_5 = output_xor_4[11:6] 	^ output_xor_4[5:0];


    assign line_index_o = output_xor_5[WORD_SIZE-1:0];

    
endmodule



module hash_cache_function_tag #(
        parameter integer WORD_SIZE = 32
    )
    (
        input  logic clk_i,
				input  logic rst_l,
				input  logic randomize_i,
        input  logic [25 : 0] addr_i ,
        output logic [WORD_SIZE-1 : 0] line_index_o 
    );

//***Interal logic generated by compiler***  
    logic [31 : 0] prng_out, random_number_w;

    logic[63:0] lfsr_seed;
`ifndef SYNTHESIS
	 initial begin
	    longint hash_seed;
	    if($value$plusargs("hash_seed=%d", hash_seed)) begin
				lfsr_seed = hash_seed;
				random_number_w = hash_seed[31:0];
				prng_out = hash_seed[31:0];
			end else begin
				lfsr_seed = '0;
			end
	 end
`else
    assign lfsr_seed = '0;
`endif
//	logic randomize_reset_ff;
//	rvdff #(1) rrff(.*, .clk(clk_i), .din(!rst_l&randomize_i), .dout(randomize_reset_ff));
   lfsr_prng #(32) lfsr (.*, .clk(clk_i), .output_number_o(prng_out), .seed_i(lfsr_seed));
	 
   rvdffs #(32) hash_key (.*,.clk(clk_i), .din (prng_out), .dout(random_number_w), .en(randomize_i));

//***Dumped Internal logic***
    reg [31:0] rotate_0;
    reg [31:0] rotate_1;
    reg [31:0] rotate_2;
    reg [31:0] rotate_3;
    wire [185:0] combined;
    wire [92:0] output_xor_1;
    wire [46:0] output_xor_2;
    wire [23:0] output_xor_3;
    wire [11:0] output_xor_4;
    wire [5:0] output_xor_5;
    
    five_rotator #(32) r1 (.num({6'b0,addr_i}), .shift(addr_i[4:0]), 					.rotated(rotate_0));
    five_rotator #(32) r2 (.num({6'b0,addr_i}), .shift(addr_i[9:5]), 					.rotated(rotate_1));
    five_rotator #(32) r3 (.num({6'b0,addr_i}), .shift(random_number_w[4:0]), .rotated(rotate_2));
    five_rotator #(32) r4 (.num({6'b0,addr_i}), .shift(random_number_w[9:5]), .rotated(rotate_3));
		
		assign combined = {rotate_0, rotate_1, rotate_2, rotate_3, addr_i, random_number_w};
    assign output_xor_1 = combined[185:93] ^ combined[92:0];
    assign output_xor_2 = output_xor_1[92:46] ^ output_xor_1[46:0];
    assign output_xor_3 = output_xor_2[46:23] ^ output_xor_2[23:0];
    assign output_xor_4 = output_xor_3[23:12] ^ output_xor_3[11:0];
    assign output_xor_5 = output_xor_4[11:6] ^ output_xor_4[5:0];


    assign line_index_o = output_xor_5[WORD_SIZE-1:0];

    
endmodule 


module pbox
    (
        input logic a,
				input logic b,
				input logic drive,
				output logic c,
				output logic d
		);
		
		assign c = drive ? a : b;
		assign d = drive ? b : a;


    
endmodule
module unrandom_modulo2 #(
        parameter integer TAG_SIZE = 10
    )
    (
        input  logic clk_i,
				input  logic rst_l,
				input  logic randomize_i,
        input  logic [31:4] addr_i ,
        output logic [3:0][1:0] permutation_o
    );

//***Interal logic generated by compiler***  
    logic [31 : 0] prng_out, random_number_w;

    logic[31:0] lfsr_seed;
`ifndef SYNTHESIS
	 initial begin
	    int hash_seed;
	    if($value$plusargs("btb_seed=%d", hash_seed)) begin
				lfsr_seed = hash_seed;
				random_number_w = hash_seed[31:0];
				prng_out = hash_seed[31:0];
			end else begin
				lfsr_seed = '0;
			end
	 end
`else
    assign lfsr_seed = '0;
`endif
		logic rst_ff;
		always_ff @(posedge clk_i) rst_ff <= rst_l;


   lfsr_prng #(32) lfsr (.*, .clk(clk_i), .output_number_o(prng_out), .seed_i(lfsr_seed));
   rvdffs #(32) key_reg (.*,.clk(clk_i), .din (prng_out), .dout(random_number_w), .en(randomize_i | !rst_ff));
   logic [3:0][1:0] inputs;
	 logic key;
	 logic[31:0] xor0;
	 logic[15:0] xor1;
	 logic[7:0]  xor2;
	 logic[3:0]  xor3;
	 logic[1:0]  xor4;
	 logic[1:0] num0, num1, num2, num3;
	
	 assign xor0 = {addr_i[31:4] ^ random_number_w[31:4], random_number_w[3:0]};
	 assign xor1 = xor0[31:16] ^ xor0[15:0];
	 assign xor2 = xor1[15:8] ^ xor1[7:0];
	 assign xor3 = xor2[7:4] ^ xor2[3:0];
	 assign xor4 = xor3[3:2] ^ xor3[1:0];
   assign key = xor4[1] ^ xor4[0];
	 assign inputs[0] = 2'b00 + xor4[1:0];
	 assign inputs[1] = 2'b01 + xor4[1:0];
	 assign inputs[2] = 2'b10 + xor4[1:0];
	 assign inputs[3] = 2'b11 + xor4[1:0];
   pbox p0 (.a(inputs[0][0]), .b(inputs[0][1]), .drive(key), .c(num0[1]), .d(num0[0]));
   pbox p1 (.a(inputs[1][0]), .b(inputs[1][1]), .drive(key), .c(num1[1]), .d(num1[0]));
   pbox p2 (.a(inputs[2][0]), .b(inputs[2][1]), .drive(key), .c(num2[1]), .d(num2[0]));
   pbox p3 (.a(inputs[3][0]), .b(inputs[3][1]), .drive(key), .c(num3[1]), .d(num3[0]));

	 assign permutation_o[0] = num0;
	 assign permutation_o[1] = num1;
	 assign permutation_o[2] = num2;
	 assign permutation_o[3] = num3;
    
endmodule


module random_modulo2 #(
        parameter integer TAG_SIZE = 10
    )
    (
        input  logic clk_i,
				input  logic rst_l,
				input  logic randomize_i,
        input  logic [31 : 2] addr_i ,
        output logic [1  : 0] permutation_o
    );

//***Interal logic generated by compiler***  
    logic [31 : 0] prng_out, random_number_w;

    logic[31:0] lfsr_seed;
`ifndef SYNTHESIS
	 initial begin
	    int hash_seed;
	    if($value$plusargs("btb_seed=%d", hash_seed)) begin
				lfsr_seed = hash_seed;
				random_number_w = hash_seed[31:0];
				prng_out = hash_seed[31:0];
			end else begin
				lfsr_seed = '0;
			end
	 end
`else
    assign lfsr_seed = '0;
`endif
		logic rst_ff;
		always_ff @(posedge clk_i) rst_ff <= rst_l;


   lfsr_prng #(32) lfsr (.*, .clk(clk_i), .output_number_o(prng_out), .seed_i(lfsr_seed));
   rvdffs #(32) key_reg (.*,.clk(clk_i), .din (prng_out), .dout(random_number_w), .en(randomize_i | !rst_ff));
   
	 logic c00,c01;
	 logic key;
	 logic[31:0] xor0;
	 logic[15:0] xor1;
	 logic[7:0]  xor2;
	 logic[3:0]  xor3;
	 logic[1:0]  xor4;
	 logic[1:0] num;
	
	 assign xor0 = {addr_i[31:4] ^ random_number_w[31:4], random_number_w[3:0]};
	 assign xor1 = xor0[31:16] ^ xor0[15:0];
	 assign xor2 = xor1[15:8] ^ xor1[7:0];
	 assign xor3 = xor2[7:4] ^ xor2[3:0];
	 assign xor4 = xor3[3:2] ^ xor3[1:0];
   assign key = xor4[1] ^ xor4[0];
	 assign num = addr_i[3:2] + xor4[1:0];

   pbox p00 (.a(num[0]), .b(num[1]), .drive(key), .c(c00), .d(c01));

	 assign permutation_o = {c00, c01};
    
endmodule

module random_modulo4 #(
        parameter integer TAG_SIZE = 10
    )
    (
        input  logic clk_i,
				input  logic rst_l,
				input  logic randomize_i,
        input  logic [31 : 4] addr_i ,
        output logic [3  : 0] permutation_o
    );

//***Interal logic generated by compiler***  
    logic [31 : 0] prng_out, random_number_w;

    logic[31:0] lfsr_seed;
`ifndef SYNTHESIS
	 initial begin
	    int hash_seed;
	    if($value$plusargs("btb_seed=%d", hash_seed)) begin
				lfsr_seed = hash_seed;
				random_number_w = hash_seed[31:0];
				prng_out = hash_seed[31:0];
			end else begin
				lfsr_seed = '0;
			end
	 end
`else
    assign lfsr_seed = '0;
`endif
		logic rst_ff;
		always_ff @(posedge clk_i) rst_ff <= rst_l;


   lfsr_prng #(32) lfsr (.*, .clk(clk_i), .output_number_o(prng_out), .seed_i(lfsr_seed));
   rvdffs #(32) key_reg (.*,.clk(clk_i), .din (prng_out), .dout(random_number_w), .en(randomize_i | !rst_ff));
   
	 logic c00,c01, c02, c03 ,c10, c11, c12, c13, c20,c21, c22, c23;
	 logic[5:0] key;
	 logic[23:0] xor0;
	 logic[11:0] xor1;
	 logic[3:0] num;
	
	 assign xor0 = addr_i[31:8] ^ random_number_w[23:0];
	 assign xor1 = xor0[23:12] ^ xor0[11:0];
   assign key = xor1[11:6] ^ xor1[5:0];
	 assign num = addr_i[7:4] + xor1[3:0];

   pbox p00 (.a(num[0]), .b(num[1]), .drive(key[0]), .c(c00), .d(c01));
   pbox p01 (.a(num[2]), .b(num[3]), .drive(key[1]), .c(c02), .d(c03));
   pbox p10 (.a(c00),    .b(c02), 	 .drive(key[2]), .c(c10), .d(c11));
   pbox p11 (.a(c01), 	 .b(c03), 	 .drive(key[3]), .c(c12), .d(c13));
   pbox p20 (.a(c10), 	 .b(c12), 	 .drive(key[4]), .c(c20), .d(c21));
   pbox p21 (.a(c11), 	 .b(c13), 	 .drive(key[5]), .c(c22), .d(c23));

	 assign permutation_o = {c20,c21, c22, c23};
    
endmodule


module random_modulo6 #(
        parameter integer TAG_SIZE = 10
    )
    (
        input  logic clk_i,
				input  logic rst_l,
				input  logic randomize_i,
        input  logic [25 : 0] addr_i ,
        output logic [5 : 0] line_index_o 
    );

//***Interal logic generated by compiler***  
    logic [31 : 0] prng_out, random_number_w;

    logic[31:0] lfsr_seed;
`ifndef SYNTHESIS
	 initial begin
	    int hash_seed;
	    if($value$plusargs("hash_seed=%d", hash_seed)) begin
				lfsr_seed = hash_seed;
				random_number_w = hash_seed[31:0];
				prng_out = hash_seed[31:0];
			end else begin
				lfsr_seed = '0;
			end
	 end
`else
    assign lfsr_seed = '0;
`endif
	logic rst_ff;
	always_ff @(posedge clk_i) rst_ff <= rst_l;

   lfsr_prng #(32) lfsr (.*, .clk(clk_i), .output_number_o(prng_out), .seed_i(lfsr_seed));
   rvdffs #(32) key_reg (.*,.clk(clk_i), .din (prng_out), .dout(random_number_w), .en(randomize_i | !rst_ff));
   logic c00,c01,c02,c03,c04,c05, c10, c11, c12, c13, c20,c21,c22,c23, c30, c31, c32, c33;
	 logic[11:0] xored, addr_xor;
	 assign addr_xor = addr_i[17:6] ^ {random_number_w[15:12] , addr_i[25:18]};
   assign xored = addr_xor ^ random_number_w[11:0];
   
	 pbox p00 (.a(addr_i[0]), .b(addr_i[1]), .drive(xored[0]), .c(c00), .d(c01));
   pbox p01 (.a(addr_i[2]), .b(addr_i[3]), .drive(xored[1]), .c(c02), .d(c03));
   pbox p02 (.a(addr_i[4]), .b(addr_i[5]), .drive(xored[2]), .c(c04), .d(c05));
   pbox p10 (.a(c00), .b(c02), .drive(xored[3]), .c(c10), .d(c11));
   pbox p11 (.a(c01), .b(c03), .drive(xored[4]), .c(c12), .d(c13));
   pbox p20 (.a(c11), .b(c04), .drive(xored[5]), .c(c20), .d(c21));
   pbox p21 (.a(c13), .b(c05), .drive(xored[6]), .c(c22), .d(c23));
   pbox p30 (.a(c10), .b(c20), .drive(xored[7]), .c(c30), .d(c31));
   pbox p31 (.a(c12), .b(c22), .drive(xored[8]), .c(c32), .d(c33));
   pbox p40 (.a(c30), .b(c32), .drive(xored[9]), .c(line_index_o[0]), .d(line_index_o[1]));
   pbox p41 (.a(c31), .b(c33), .drive(xored[10]), .c(line_index_o[2]), .d(line_index_o[3]));
   pbox p42 (.a(c21), .b(c23), .drive(xored[11]), .c(line_index_o[4]), .d(line_index_o[5]));
    
endmodule


