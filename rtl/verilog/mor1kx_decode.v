/* ****************************************************************************
  This Source Code Form is subject to the terms of the
  Open Hardware Description License, v. 1.0. If a copy
  of the OHDL was not distributed with this file, You
  can obtain one at http://juliusbaxter.net/ohdl/ohdl.txt

  Description: mor1kx decode unit

  Outputs:
   - ALU operation
   - indication of other type of op - LSU/SPR
   - immediates
   - register file addresses
   - exception decodes:  illegal, system call

  Copyright (C) 2012 Authors

  Author(s): Julius Baxter <juliusbaxter@gmail.com>

***************************************************************************** */

`include "mor1kx-defines.v"

module mor1kx_decode
  #(
    parameter OPTION_OPERAND_WIDTH = 32,
    parameter OPTION_RESET_PC = {{(OPTION_OPERAND_WIDTH-13){1'b0}},
				 `OR1K_RESET_VECTOR,8'd0},
    parameter OPTION_RF_ADDR_WIDTH = 5,

    parameter FEATURE_SYSCALL = "ENABLED",
    parameter FEATURE_TRAP = "ENABLED",
    parameter FEATURE_RANGE = "ENABLED",
    parameter FEATURE_MAC = "NONE",
    parameter FEATURE_MULTIPLIER = "PARALLEL",
    parameter FEATURE_DIVIDER = "NONE",

    parameter FEATURE_ADDC = "NONE",
    parameter FEATURE_SRA = "ENABLED",
    parameter FEATURE_ROR = "NONE",
    parameter FEATURE_EXT = "NONE",
    parameter FEATURE_CMOV = "NONE",
    parameter FEATURE_FFL1 = "NONE",

    parameter FEATURE_CUST1 = "NONE",
    parameter FEATURE_CUST2 = "NONE",
    parameter FEATURE_CUST3 = "NONE",
    parameter FEATURE_CUST4 = "NONE",
    parameter FEATURE_CUST5 = "NONE",
    parameter FEATURE_CUST6 = "NONE",
    parameter FEATURE_CUST7 = "NONE",
    parameter FEATURE_CUST8 = "NONE",

    parameter FEATURE_DELAY_SLOT = "ENABLED",

    parameter REGISTERED_DECODE = "ENABLED",
    parameter PIPELINE_BUBBLE = "NONE",
    parameter FEATURE_INBUILT_CHECKERS = "ENABLED"
    )
   (
    input 				  clk,
    input 				  rst,

    // pipeline control signal in
    input 				  padv_i,

    // input from fetch stage
    input [OPTION_OPERAND_WIDTH-1:0] 	  pc_decode_i,
    input [`OR1K_INSN_WIDTH-1:0] 	  decode_insn_i,

    // input from register file
    input [OPTION_OPERAND_WIDTH-1:0] 	  decode_rfb_i,
    input [OPTION_OPERAND_WIDTH-1:0] 	  execute_rfb_i,

    // input from execute stage
    input 				  flag_i,
    input 				  flag_set_i,
    input 				  flag_clear_i,

    input 				  pipeline_flush_i,

    //outputs to ALU
    output reg [`OR1K_ALU_OPC_WIDTH-1:0]  opc_alu_o,
    output reg [`OR1K_ALU_OPC_WIDTH-1:0]  opc_alu_secondary_o,

    output reg [`OR1K_IMM_WIDTH-1:0] 	  imm16_o,
    output reg [OPTION_OPERAND_WIDTH-1:0] immediate_o,
    output reg 				  immediate_sel_o,

    // Upper 10 bits of immediate for jumps and branches
    output reg [9:0] 			  immjbr_upper_o,

    // GPR numbers
    output reg [OPTION_RF_ADDR_WIDTH-1:0] execute_rfd_adr_o,
    output [OPTION_RF_ADDR_WIDTH-1:0] 	  decode_rfd_adr_o,
    output [OPTION_RF_ADDR_WIDTH-1:0] 	  decode_rfa_adr_o,
    output [OPTION_RF_ADDR_WIDTH-1:0] 	  decode_rfb_adr_o,
    input [OPTION_RF_ADDR_WIDTH-1:0] 	  ctrl_rfd_adr_i,
    input 				  ctrl_op_lsu_load_i,
    input 				  ctrl_op_mfspr_i,

    output reg [OPTION_OPERAND_WIDTH-1:0] execute_jal_result_o,

    output reg 				  rf_wb_o,

    output reg 				  op_jbr_o,
    output reg 				  op_jr_o,
    output reg 				  op_jal_o,
    output reg 				  op_branch_o,

    output reg 				  op_alu_o,

    output reg 				  op_lsu_load_o,
    output reg 				  op_lsu_store_o,
    output reg [1:0] 			  lsu_length_o,
    output reg 				  lsu_zext_o,

    output reg 				  op_mfspr_o,
    output reg 				  op_mtspr_o,

    output reg 				  op_rfe_o,

    // branch detection
    output 				  decode_branch_o,
    output [OPTION_OPERAND_WIDTH-1:0] 	  decode_branch_target_o,

    // exceptions in
    input 				  decode_except_ibus_err_i,
    input 				  decode_except_itlb_miss_i,
    input 				  decode_except_ipagefault_i,

    // exception output -
    output reg 				  execute_except_ibus_err_o,
    output reg 				  execute_except_itlb_miss_o,
    output reg 				  execute_except_ipagefault_o,
    output reg 				  execute_except_illegal_o,
    output reg 				  execute_except_ibus_align_o,
    output reg 				  execute_except_syscall_o,
    output reg 				  execute_except_trap_o,

    // output is valid, signal
    output reg [OPTION_OPERAND_WIDTH-1:0] pc_execute_o,

    output reg 				  decode_valid_o,

    output 				  decode_bubble_o,
    output reg 				  execute_bubble_o,

    output reg [`OR1K_OPCODE_WIDTH-1:0]   opc_insn_o
    );

   wire [`OR1K_ALU_OPC_WIDTH-1:0] 	opc_alu;
   wire [`OR1K_ALU_OPC_WIDTH-1:0] 	opc_alu_secondary;

   wire [`OR1K_IMM_WIDTH-1:0] 		imm16;
   wire [OPTION_OPERAND_WIDTH-1:0] 	immediate;
   wire [9:0] 				immjbr_upper;
   wire 				immediate_sel;

   wire 				decode_except_ibus_align;
   reg 					execute_except_illegal;
   wire 				execute_except_ibus_err;
   wire 				execute_except_itlb_miss;
   wire 				execute_except_ipagefault;
   wire 				execute_except_syscall;
   wire 				execute_except_trap;

   wire [OPTION_OPERAND_WIDTH-1:0] 	 pc_execute;
   wire [`OR1K_OPCODE_WIDTH-1:0] 	 opc_insn;


   wire 				 rf_wb;

   wire 				 op_load;
   wire 				 op_store;
   reg [1:0] 				 lsu_length;
   wire 				 lsu_zext;
   wire 				 opc_mtspr;
   wire 				 opc_setflag;
   wire 				 op_alu;
   wire 				 op_jbr;
   wire 				 op_jr;
   wire 				 op_jal;
   wire 				 op_branch;
   wire 				 op_mfspr;
   wire 				 op_rfe;

   wire 				 flag;

   wire 				 imm_sext_sel;
   wire 				 imm_zext_sel;
   wire 				 imm_high_sel;

   // load opcodes are 6'b10_0000 to 6'b10_0110, 0 to 6, so check for 7 and up
   assign op_load = (decode_insn_i[31:30]==2'b10) & !(&decode_insn_i[28:26])&
		    !decode_insn_i[29];

   // Detect when instruction is store
   assign op_store = (decode_insn_i[`OR1K_OPCODE_SELECT] == `OR1K_OPCODE_SW) ||
		     (decode_insn_i[`OR1K_OPCODE_SELECT] == `OR1K_OPCODE_SB) ||
		     (decode_insn_i[`OR1K_OPCODE_SELECT] == `OR1K_OPCODE_SH);

   // Decode length of load/store operation
   always @(*)
     case (opc_insn)
       `OR1K_OPCODE_SB,
       `OR1K_OPCODE_LBZ,
       `OR1K_OPCODE_LBS:
	 lsu_length = 2'b00;

       `OR1K_OPCODE_SH,
       `OR1K_OPCODE_LHZ,
       `OR1K_OPCODE_LHS:
	 lsu_length = 2'b01;

       `OR1K_OPCODE_SW,
       `OR1K_OPCODE_LWZ,
       `OR1K_OPCODE_LWS:
	 lsu_length = 2'b10;

       default:
	 lsu_length = 2'b10;
     endcase

   assign lsu_zext = opc_insn[0];

   assign opc_mtspr = (decode_insn_i[`OR1K_OPCODE_SELECT] ==
		       `OR1K_OPCODE_MTSPR);

   // Detect when setflag instruction
   assign opc_setflag = decode_insn_i[`OR1K_OPCODE_SELECT] == `OR1K_OPCODE_SF ||
			decode_insn_i[`OR1K_OPCODE_SELECT] ==
			`OR1K_OPCODE_SFIMM;

   // Detect which instructions will be generating a result from the ALU
   assign op_alu = ((decode_insn_i[31:30]==2'b10) &
		    //l.addi and the rest...
		    (decode_insn_i[28:26]==3'b111 | decode_insn_i[29])) |
		   // all normal ALU ops, and l.cust5-8
		   decode_insn_i[31:29]==3'b111 |
		   // l.mt/fspr - need address out of ALU
		   opc_mtspr |
		   (decode_insn_i[`OR1K_OPCODE_SELECT] == `OR1K_OPCODE_MFSPR) |
		   (decode_insn_i[`OR1K_OPCODE_SELECT]==`OR1K_OPCODE_MOVHI);

   // Bottom 4 opcodes branch against an immediate
   assign op_jbr = decode_insn_i[`OR1K_OPCODE_SELECT] < `OR1K_OPCODE_NOP;

   assign op_jr = decode_insn_i[`OR1K_OPCODE_SELECT]==`OR1K_OPCODE_JR |
		  decode_insn_i[`OR1K_OPCODE_SELECT]==`OR1K_OPCODE_JALR;

   assign op_jal = decode_insn_i[`OR1K_OPCODE_SELECT]==`OR1K_OPCODE_JALR |
		   decode_insn_i[`OR1K_OPCODE_SELECT]==`OR1K_OPCODE_JAL;

   // All branch instructions combined
   assign op_branch = op_jbr | op_jr | op_jal;

   assign op_mfspr = decode_insn_i[`OR1K_OPCODE_SELECT]==`OR1K_OPCODE_MFSPR;

   assign op_rfe = decode_insn_i[`OR1K_OPCODE_SELECT]==`OR1K_OPCODE_RFE;

   // Which instructions cause writeback?
   assign rf_wb = (decode_insn_i[`OR1K_OPCODE_SELECT]==`OR1K_OPCODE_JAL |
		   decode_insn_i[`OR1K_OPCODE_SELECT]==`OR1K_OPCODE_MOVHI |
		   decode_insn_i[`OR1K_OPCODE_SELECT]==`OR1K_OPCODE_JALR) |
		  // All '10????' opcodes except l.sfxxi
		  (decode_insn_i[31:30]==2'b10 &
		   !(decode_insn_i[`OR1K_OPCODE_SELECT]==`OR1K_OPCODE_SFIMM)) |
		  // All '11????' opcodes except l.sfxx and l.mtspr
		  (decode_insn_i[31:30]==2'b11 &
		   !(decode_insn_i[`OR1K_OPCODE_SELECT]==`OR1K_OPCODE_SF |
		     opc_mtspr | op_store));

   // Register file addresses are not registered here, but rather go
   // straight out to RF so read is done when execute stage is ready
   assign decode_rfa_adr_o = decode_insn_i[`OR1K_RA_SELECT];
   assign decode_rfb_adr_o = decode_insn_i[`OR1K_RB_SELECT];

   assign decode_rfd_adr_o = op_jal ? 9 : decode_insn_i[`OR1K_RD_SELECT];

   // Insn opcode
   assign opc_insn = decode_insn_i[`OR1K_OPCODE_SELECT];
   // Immediate in l.mtspr is broken up, reassemble
   assign imm16 = (opc_mtspr | op_store) ?
		  {decode_insn_i[25:21],decode_insn_i[10:0]} :
		  decode_insn_i[`OR1K_IMM_SELECT];


   // Upper 10 bits for jump/branch instructions
   assign immjbr_upper = decode_insn_i[25:16];

   assign imm_sext_sel = ((opc_insn[5:4] == 2'b10) &
                          ~(opc_insn==`OR1K_OPCODE_ORI) &
                          ~(opc_insn==`OR1K_OPCODE_ANDI)) |
                         (opc_insn==`OR1K_OPCODE_SW) |
                         (opc_insn==`OR1K_OPCODE_SH) |
                         (opc_insn==`OR1K_OPCODE_SB);

   assign imm_zext_sel = ((opc_insn[5:4] == 2'b10) &
                          ((opc_insn==`OR1K_OPCODE_ORI) |
			   (opc_insn==`OR1K_OPCODE_ANDI))) |
                         (opc_insn==`OR1K_OPCODE_MTSPR);

   assign imm_high_sel = opc_insn == `OR1K_OPCODE_MOVHI;

   assign immediate = imm_sext_sel ? {{16{imm16[15]}},imm16[15:0]} :
		      imm_zext_sel ? {{16{1'b0}},imm16[15:0]} :
		      {imm16,16'd0}; // imm_high_sel

   assign immediate_sel = imm_sext_sel | imm_zext_sel | imm_high_sel;

   // ALU opcode
   assign opc_alu = (op_jbr | op_jal) ? `OR1K_ALU_OPC_ADD :
		    decode_insn_i[`OR1K_ALU_OPC_SELECT];
   assign opc_alu_secondary = opc_setflag ?
			      decode_insn_i[`OR1K_COMP_OPC_SELECT]:
			      {1'b0,
			       decode_insn_i[`OR1K_ALU_OPC_SECONDAY_SELECT]};

   assign execute_except_ibus_err = decode_except_ibus_err_i;
   assign execute_except_itlb_miss = decode_except_itlb_miss_i;
   assign execute_except_ipagefault = decode_except_ipagefault_i;

   assign execute_except_syscall = decode_insn_i[`OR1K_OPCODE_SELECT] ==
				   `OR1K_OPCODE_SYSTRAPSYNC &&
				   decode_insn_i[`OR1K_SYSTRAPSYNC_OPC_SELECT] ==
				   `OR1K_SYSTRAPSYNC_OPC_SYSCALL;
   assign execute_except_trap = decode_insn_i[`OR1K_OPCODE_SELECT] ==
				`OR1K_OPCODE_SYSTRAPSYNC &&
				decode_insn_i[`OR1K_SYSTRAPSYNC_OPC_SELECT] ==
				`OR1K_SYSTRAPSYNC_OPC_TRAP;

   assign pc_execute = pc_decode_i;

   // Flag calculation, we get the flag_set_i and flag_clear_i straight from
   // execute stage, and we keep track of the value.
   reg 					 pipeline_flush_r;
   always @(posedge clk)
     pipeline_flush_r <= pipeline_flush_i;

   reg 					 flag_r;
   always @(posedge clk)
     if (pipeline_flush_r)
       flag_r <= flag_i;
     else if (flag_set_i)
       flag_r <= 1;
     else if (flag_clear_i)
       flag_r <= 0;

   assign flag = pipeline_flush_r ? flag_i :
		 (!flag_clear_i & flag_r) | flag_set_i;

   // Branch detection
   wire 				 ctrl_to_decode_interlock;
   assign ctrl_to_decode_interlock = (ctrl_op_lsu_load_i | ctrl_op_mfspr_i) &
				     (decode_rfb_adr_o == ctrl_rfd_adr_i);

   wire imm_branch = (op_jbr &
		      // l.j/l.jal
		      (!(|opc_insn[2:1]) |
		       // l.bf/bnf and flag is right
		       (opc_insn[2] == flag)));

   wire reg_branch = op_jr & !ctrl_to_decode_interlock;

   assign decode_branch_o = (imm_branch | reg_branch) & !pipeline_flush_i &
			    !decode_bubble_o;
   assign decode_branch_target_o = imm_branch ?
				   pc_decode_i + {{4{immjbr_upper[9]}},
						  immjbr_upper,imm16,2'b00} :
				   // If a bubble have been pushed out to get
				   // the instruction that will write the
				   // branch target to control stage, then we
				   // need to use the register result from
				   // execute stage instead of decode stage.
				   execute_bubble_o | op_jr_o ?
				   execute_rfb_i : decode_rfb_i;

   assign decode_except_ibus_align = decode_branch_o &
				     (|decode_branch_target_o[1:0]);

   // Calculate the link register result
   // TODO: investigate if the ALU adder can be used for this without
   // introducing critical paths
   always @(posedge clk)
     if (padv_i)
       execute_jal_result_o <= FEATURE_DELAY_SLOT == "ENABLED" ?
			       pc_decode_i + 8 :
			       pc_decode_i + 4;

generate
/* verilator lint_off WIDTH */
if (PIPELINE_BUBBLE=="ENABLED") begin : pipeline_bubble
/* verilator lint_on WIDTH */

   // Detect the situation where there is an instruction in execute stage
   // that will produce it's result in control stage (i.e. load and mfspr),
   // and an instruction currently in decode stage needing it's result as
   // input in execute stage.
   // Also detect the situation where there is a jump to register in decode
   // stage and an instruction in execute stage that will write to that
   // register.
   //
   // A bubble is also inserted when an rfe instruction is in decode stage,
   // the main purpose of this is to stall fetch while the rfe is propagating
   // up to ctrl stage.

   assign decode_bubble_o = ((op_lsu_load_o | op_mfspr_o) &
			     (decode_rfa_adr_o == execute_rfd_adr_o ||
			      decode_rfb_adr_o == execute_rfd_adr_o) |
			     op_jr &
			     (ctrl_to_decode_interlock |
			      (decode_rfb_adr_o == execute_rfd_adr_o)) |
			     op_rfe) & padv_i;

end else begin
   assign decode_bubble_o = 0;
end
endgenerate

   always @(posedge clk `OR_ASYNC_RST)
     if (rst)
       execute_bubble_o <= 0;
     else if (pipeline_flush_i)
       execute_bubble_o <= 0;
     else if (padv_i)
       execute_bubble_o <= decode_bubble_o;

   // Illegal instruction decode
   always @*
     case (decode_insn_i[`OR1K_OPCODE_SELECT])
       `OR1K_OPCODE_J,
       `OR1K_OPCODE_JAL,
       `OR1K_OPCODE_BNF,
       `OR1K_OPCODE_BF,
       `OR1K_OPCODE_MOVHI,
       `OR1K_OPCODE_RFE,
       `OR1K_OPCODE_JR,
       `OR1K_OPCODE_JALR,
       `OR1K_OPCODE_LWZ,
       `OR1K_OPCODE_LWS,
       `OR1K_OPCODE_LBZ,
       `OR1K_OPCODE_LBS,
       `OR1K_OPCODE_LHZ,
       `OR1K_OPCODE_LHS,
       `OR1K_OPCODE_ADDI,
       `OR1K_OPCODE_ANDI,
       `OR1K_OPCODE_ORI,
       `OR1K_OPCODE_XORI,
       `OR1K_OPCODE_MFSPR,
       /*
	`OR1K_OPCODE_SLLI,
	`OR1K_OPCODE_SRLI,
	`OR1K_OPCODE_SRAI,
	`OR1K_OPCODE_RORI,
	*/
       `OR1K_OPCODE_SFIMM,
       `OR1K_OPCODE_MTSPR,
       `OR1K_OPCODE_SW,
       `OR1K_OPCODE_SB,
       `OR1K_OPCODE_SH,
       /*
	`OR1K_OPCODE_SFEQ,
	`OR1K_OPCODE_SFNE,
	`OR1K_OPCODE_SFGTU,
	`OR1K_OPCODE_SFGEU,
	`OR1K_OPCODE_SFLTU,
	`OR1K_OPCODE_SFLEU,
	`OR1K_OPCODE_SFGTS,
	`OR1K_OPCODE_SFGES,
	`OR1K_OPCODE_SFLTS,
	`OR1K_OPCODE_SFLES,
	*/
       `OR1K_OPCODE_SF,
       `OR1K_OPCODE_NOP:
	 execute_except_illegal = 1'b0;

       `OR1K_OPCODE_CUST1:
	 execute_except_illegal = (FEATURE_CUST1=="NONE");
       `OR1K_OPCODE_CUST2:
	 execute_except_illegal = (FEATURE_CUST2=="NONE");
       `OR1K_OPCODE_CUST3:
	 execute_except_illegal = (FEATURE_CUST3=="NONE");
       `OR1K_OPCODE_CUST4:
	 execute_except_illegal = (FEATURE_CUST4=="NONE");
       `OR1K_OPCODE_CUST5:
	 execute_except_illegal = (FEATURE_CUST5=="NONE");
       `OR1K_OPCODE_CUST6:
	 execute_except_illegal = (FEATURE_CUST6=="NONE");
       `OR1K_OPCODE_CUST7:
	 execute_except_illegal = (FEATURE_CUST7=="NONE");
       `OR1K_OPCODE_CUST8:
	 execute_except_illegal = (FEATURE_CUST8=="NONE");

       `OR1K_OPCODE_LD,
	 `OR1K_OPCODE_SD:
	   execute_except_illegal = !(OPTION_OPERAND_WIDTH==64);

       `OR1K_OPCODE_ADDIC:
	 execute_except_illegal = (FEATURE_ADDC=="NONE");

       //`OR1K_OPCODE_MACRC, // Same as movhi - check!
       `OR1K_OPCODE_MACI,
	 `OR1K_OPCODE_MAC:
	   execute_except_illegal = (FEATURE_MAC=="NONE");

       `OR1K_OPCODE_MULI:
	 execute_except_illegal = (FEATURE_MULTIPLIER=="NONE");

       `OR1K_OPCODE_SHRTI:
	 case(decode_insn_i[`OR1K_ALU_OPC_SECONDAY_SELECT])
	   `OR1K_ALU_OPC_SECONDARY_SHRT_SLL,
	   `OR1K_ALU_OPC_SECONDARY_SHRT_SRL:
	     execute_except_illegal = 1'b0;
	   `OR1K_ALU_OPC_SECONDARY_SHRT_SRA:
	     execute_except_illegal = (FEATURE_SRA=="NONE");

	   `OR1K_ALU_OPC_SECONDARY_SHRT_ROR:
	     execute_except_illegal = (FEATURE_ROR=="NONE");
	   default:
	     execute_except_illegal = 1'b1;
	 endcase // case (decode_insn_i[`OR1K_ALU_OPC_SECONDAY_SELECT])

       `OR1K_OPCODE_ALU:
	 case(decode_insn_i[`OR1K_ALU_OPC_SELECT])
	   `OR1K_ALU_OPC_ADD,
	   `OR1K_ALU_OPC_SUB,
	   `OR1K_ALU_OPC_OR,
	   `OR1K_ALU_OPC_XOR,
	   `OR1K_ALU_OPC_AND:
	     execute_except_illegal = 1'b0;
	   `OR1K_ALU_OPC_CMOV:
	     execute_except_illegal = (FEATURE_CMOV=="NONE");
	   `OR1K_ALU_OPC_FFL1:
	     execute_except_illegal = (FEATURE_FFL1=="NONE");
	   `OR1K_ALU_OPC_DIV,
	     `OR1K_ALU_OPC_DIVU:
	       execute_except_illegal = (FEATURE_DIVIDER=="NONE");
	   `OR1K_ALU_OPC_ADDC:
	     execute_except_illegal = (FEATURE_ADDC=="NONE");
	   `OR1K_ALU_OPC_MUL,
	     `OR1K_ALU_OPC_MULU:
	       execute_except_illegal = (FEATURE_MULTIPLIER=="NONE");
	   `OR1K_ALU_OPC_EXTBH,
	     `OR1K_ALU_OPC_EXTW:
	       execute_except_illegal = (FEATURE_EXT=="NONE");
	   `OR1K_ALU_OPC_SHRT:
	     case(decode_insn_i[`OR1K_ALU_OPC_SECONDAY_SELECT])
	       `OR1K_ALU_OPC_SECONDARY_SHRT_SLL,
	       `OR1K_ALU_OPC_SECONDARY_SHRT_SRL:
		 execute_except_illegal = 1'b0;
	       `OR1K_ALU_OPC_SECONDARY_SHRT_SRA:
		 execute_except_illegal = (FEATURE_SRA=="NONE");
	       `OR1K_ALU_OPC_SECONDARY_SHRT_ROR:
		 execute_except_illegal = (FEATURE_ROR=="NONE");
	       default:
		 execute_except_illegal = 1'b1;
	     endcase // case (decode_insn_i[`OR1K_ALU_OPC_SECONDAY_SELECT])
	   default:
	     execute_except_illegal = 1'b1;
	 endcase // case (decode_insn_i[`OR1K_ALU_OPC_SELECT])

       `OR1K_OPCODE_SYSTRAPSYNC: begin
	  if ((decode_insn_i[`OR1K_SYSTRAPSYNC_OPC_SELECT] ==
	       `OR1K_SYSTRAPSYNC_OPC_SYSCALL &&
	       FEATURE_SYSCALL=="ENABLED") ||
	      (decode_insn_i[`OR1K_SYSTRAPSYNC_OPC_SELECT] ==
	       `OR1K_SYSTRAPSYNC_OPC_TRAP &&
	       FEATURE_TRAP=="ENABLED"))
	    execute_except_illegal = 1'b0;
	  else
	    execute_except_illegal = 1'b1;
       end // case: endcase...
       default:
	 execute_except_illegal = 1'b1;

     endcase // case (decode_insn_i[`OR1K_OPCODE_SELECT])


   generate
      if (REGISTERED_DECODE == "ENABLED") begin : registered_decode
	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst) begin
	      rf_wb_o <= 0;
	      execute_rfd_adr_o <= 0;
	   end
	   else if (padv_i) begin
	      rf_wb_o <= rf_wb;
	      execute_rfd_adr_o <= decode_rfd_adr_o;
	      if (decode_bubble_o) begin
		 rf_wb_o <= 0;
		 execute_rfd_adr_o <= 0;
	      end
	   end

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst) begin
	      op_jbr_o <= 0;
	      op_jr_o <= 0;
	      op_jal_o <= 0;
	      op_branch_o <= 0;
	   end
	   else if (pipeline_flush_i)
	     begin
		op_jbr_o <= 0;
		op_jr_o <= 0;
		op_jal_o <= 0;
		op_branch_o <= 0;
	     end
	   else if (padv_i) begin
	      op_jbr_o <= op_jbr;
	      op_jr_o <= op_jr;
	      op_jal_o <= op_jal;
	      op_branch_o <= op_branch;
	      if (decode_bubble_o) begin
		 op_jbr_o <= 0;
		 op_jr_o <= 0;
		 op_jal_o <= 0;
		 op_branch_o <= 0;
	      end
	   end

	 // rfe is a special case, instead of pushing the pipeline full
	 // of nops, we push it full of rfes.
	 // The reason for this is that we need the rfe to reach control
	 // stage so it will cause the branch.
	 // It will clear itself by the pipeline_flush_i that the rfe
	 // will generate.
	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     op_rfe_o <= 0;
	   else if (pipeline_flush_i)
	     op_rfe_o <= 0;
	   else if (padv_i)
	     op_rfe_o <= op_rfe;

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     op_alu_o <= 1'b0;
	   else if (padv_i) begin
	     op_alu_o <= op_alu;
	      if (decode_bubble_o)
		op_alu_o <= 0;
	   end

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     begin
		op_lsu_load_o <= 0;
		op_lsu_store_o <= 0;
	     end
	   else if (pipeline_flush_i)
	     begin
		op_lsu_load_o <= 0;
		op_lsu_store_o <= 0;
	     end
	   else if (padv_i) begin
       	      op_lsu_load_o <= op_load;
	      op_lsu_store_o <= op_store;
	      if (decode_bubble_o) begin
       		 op_lsu_load_o <= 0;
		 op_lsu_store_o <= 0;
	      end
	   end

	 always @(posedge clk)
	   if (padv_i) begin
	      lsu_length_o <= lsu_length;
	      lsu_zext_o <= lsu_zext;
	   end

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst) begin
	      op_mfspr_o <= 1'b0;
	      op_mtspr_o <= 1'b0;
	   end else if (padv_i) begin
	      op_mfspr_o <= op_mfspr;
	      op_mtspr_o <= opc_mtspr;
	      if (decode_bubble_o) begin
		 op_mtspr_o <= 1'b0;
		 op_mfspr_o <= 1'b0;
	      end
	   end

	 always @(posedge clk)
	   if (padv_i) begin
	      imm16_o <= imm16;
	      immediate_o <= immediate;
	      immediate_sel_o <= immediate_sel;
	   end

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     immjbr_upper_o <= 0;
	   else if (padv_i )
	     immjbr_upper_o <= immjbr_upper;

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst) begin
	      opc_alu_o <= 0;
	      opc_alu_secondary_o <= 0;
	   end
	   else if (padv_i) begin
	      opc_alu_o <= opc_alu;
	      opc_alu_secondary_o <= opc_alu_secondary;
	      if (decode_bubble_o) begin
		 opc_alu_o <= 0;
		 opc_alu_secondary_o <= 0;
	      end
	   end

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     opc_insn_o <= `OR1K_OPCODE_NOP;
	   else if (pipeline_flush_i)
	     opc_insn_o <= `OR1K_OPCODE_NOP;
	   else if (padv_i) begin
	      opc_insn_o <= opc_insn;
	      if (decode_bubble_o)
		opc_insn_o <= `OR1K_OPCODE_NOP;
	   end

	 // Decode for system call exception
	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     execute_except_syscall_o <= 0;
	   else if (padv_i && FEATURE_SYSCALL=="ENABLED")
	     execute_except_syscall_o <= execute_except_syscall;

	 // Decode for system call exception
	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     execute_except_trap_o <= 0;
	   else if (padv_i && FEATURE_TRAP=="ENABLED")
	     execute_except_trap_o <= execute_except_trap;

	 // Decode Illegal instruction
	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     execute_except_illegal_o <= 0;
	   else if (padv_i )
	     execute_except_illegal_o <= execute_except_illegal;

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     execute_except_ibus_err_o <= 1'b0;
	   else if (padv_i )
	     execute_except_ibus_err_o <= execute_except_ibus_err;

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     execute_except_itlb_miss_o <= 1'b0;
	   else if (padv_i )
	     execute_except_itlb_miss_o <= execute_except_itlb_miss;

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     execute_except_ipagefault_o <= 1'b0;
	   else if (padv_i )
	     execute_except_ipagefault_o <= execute_except_ipagefault;

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     execute_except_ibus_align_o <= 1'b0;
	   else if (padv_i )
	     execute_except_ibus_align_o <= decode_except_ibus_align;

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     decode_valid_o <= 0;
	   else
	     decode_valid_o <= padv_i ;

	 always @(posedge clk `OR_ASYNC_RST)
	   if (rst)
	     pc_execute_o <= OPTION_RESET_PC;
	   else if (padv_i )
	     pc_execute_o <= pc_execute;

      end // block: registered_decode
      else begin : combinatorial_decode
	 always @*
	   begin
	      execute_rfd_adr_o = decode_rfd_adr_o;
	      rf_wb_o			= rf_wb;

	      op_jbr_o			= op_jbr;
	      op_jr_o			= op_jr;
	      op_jal_o			= op_jal;
	      op_branch_o		= op_branch;
	      op_rfe_o			= op_rfe;


	      op_alu_o			= op_alu;

       	      op_lsu_load_o		= op_load;
	      op_lsu_store_o		= op_store;
	      lsu_length_o		= lsu_length;
	      lsu_zext_o		= lsu_zext;

	      op_mfspr_o		= op_mfspr;
	      op_mtspr_o		= opc_mtspr;

	      imm16_o			= imm16;
	      immjbr_upper_o		= immjbr_upper;
	      immediate_o		= immediate;
	      immediate_sel_o		= immediate_sel;

	      opc_alu_o			= opc_alu;
	      opc_alu_secondary_o	= opc_alu_secondary;

	      opc_insn_o		= opc_insn;

	      execute_except_syscall_o	= execute_except_syscall;
	      execute_except_trap_o	= execute_except_trap;
	      execute_except_illegal_o	= execute_except_illegal;
	      execute_except_ibus_err_o = execute_except_ibus_err;
	      execute_except_itlb_miss_o  = execute_except_itlb_miss;
	      execute_except_ipagefault_o = execute_except_ipagefault;
	      execute_except_ibus_align_o = decode_except_ibus_align;

	      decode_valid_o		= padv_i ;

	      pc_execute_o		= pc_execute;
	   end
      end
   endgenerate

   // synthesis translate_off
   generate
      if (FEATURE_INBUILT_CHECKERS != "NONE") begin
	 // assert on l.bnf/l.bf and flag is 'x'
	 always @(posedge clk)
	    if (padv_i & !rst & !pipeline_flush_i &
		op_jbr & (|opc_insn[2:1]) & flag === 1'bx) begin
	       $display("ERROR: flag === 'x' on l.b(n)f");
	       $finish();
	    end

      end
   endgenerate
   // synthesis translate_on
endmodule // mor1kx_decode
