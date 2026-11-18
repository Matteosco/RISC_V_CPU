-------------------------------------------------------------------------------
-- riscv_pkg.vhd
-- Shared types, constants and helper functions for the RV32I pipelined core.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

package riscv_pkg is

    ---------------------------------------------------------------------------
    -- Basic types
    ---------------------------------------------------------------------------
    subtype word_t     is std_logic_vector(31 downto 0);
    subtype reg_addr_t is std_logic_vector(4 downto 0);
    type    word_array_t is array (natural range <>) of word_t;

    constant ZERO_WORD : word_t := (others => '0');

    ---------------------------------------------------------------------------
    -- Opcodes (instr[6:0])
    ---------------------------------------------------------------------------
    subtype opcode_t is std_logic_vector(6 downto 0);
    constant OPC_LUI    : opcode_t := "0110111";
    constant OPC_AUIPC  : opcode_t := "0010111";
    constant OPC_JAL    : opcode_t := "1101111";
    constant OPC_JALR   : opcode_t := "1100111";
    constant OPC_BRANCH : opcode_t := "1100011";
    constant OPC_LOAD   : opcode_t := "0000011";
    constant OPC_STORE  : opcode_t := "0100011";
    constant OPC_OPIMM  : opcode_t := "0010011";
    constant OPC_OP     : opcode_t := "0110011";
    constant OPC_FENCE  : opcode_t := "0001111";
    constant OPC_SYSTEM : opcode_t := "1110011";

    ---------------------------------------------------------------------------
    -- Control encodings
    ---------------------------------------------------------------------------
    -- alu_opcode: the slides use funct3 as ALU opcode (plus SUB); RV32I needs
    -- ten operations, so they are listed by name
    type alu_op_t is (ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
                      ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR, ALU_AND);
    type alu_a_sel_t is (A_RS1, A_PC, A_ZERO);   -- a_sel: rs1_value / curr_pc / 0 (lui)
    type alu_b_sel_t is (B_RS2, B_IMM);          -- b_sel: rs2_value / immediate
    type csr_op_t    is (CSR_NONE, CSR_RW, CSR_RS, CSR_RC);  -- write / set / clear
    type imm_type_t  is (IMM_I, IMM_S, IMM_B, IMM_U, IMM_J, IMM_NONE);

    -- op_class[4:0] = OSLBJ, one-hot (slides): the kind of instruction
    subtype op_class_t is std_logic_vector(4 downto 0);
    constant OC_O : natural := 4;   -- Op    : ALU operation, lui, auipc, csr
    constant OC_S : natural := 3;   -- Store
    constant OC_L : natural := 2;   -- Load
    constant OC_B : natural := 1;   -- Branch (conditional)
    constant OC_J : natural := 0;   -- Jump   (jal, jalr)
    constant OC_NONE : op_class_t := "00000";   -- fence, mret, bubble: no class

    -- Control word produced by the decoder in ID and carried down the pipe
    type ctrl_t is record
        op_class    : op_class_t;                     -- OSLBJ
        rd_write_en : std_logic;                      -- O, L, J write rd
        alu_opcode  : alu_op_t;
        a_sel       : alu_a_sel_t;
        b_sel       : alu_b_sel_t;
        cond_opcode : std_logic_vector(2 downto 0);   -- comparator (= funct3)
        imm_type    : imm_type_t;
        funct3      : std_logic_vector(2 downto 0);   -- load/store size & sign
        uses_rs1    : std_logic;                      -- for precise hazard checks
        uses_rs2    : std_logic;
        csr_op      : csr_op_t;                       -- Zicsr instruction
        csr_imm     : std_logic;                      -- csrr*i: source is the rs1 field
        mret        : std_logic;                      -- return from trap
        illegal     : std_logic;
    end record;

    constant CTRL_BUBBLE : ctrl_t := (
        op_class    => OC_NONE, rd_write_en => '0',
        alu_opcode  => ALU_ADD, a_sel => A_RS1, b_sel => B_IMM,
        cond_opcode => "000", imm_type => IMM_I, funct3 => "000",
        uses_rs1    => '0', uses_rs2 => '0',
        csr_op      => CSR_NONE, csr_imm => '0', mret => '0', illegal => '0');

    -- Load/store funct3 values
    constant F3_B  : std_logic_vector(2 downto 0) := "000";
    constant F3_H  : std_logic_vector(2 downto 0) := "001";
    constant F3_W  : std_logic_vector(2 downto 0) := "010";
    constant F3_BU : std_logic_vector(2 downto 0) := "100";
    constant F3_HU : std_logic_vector(2 downto 0) := "101";

    ---------------------------------------------------------------------------
    -- Memory map (see README)
    ---------------------------------------------------------------------------
    constant RESET_VECTOR : word_t := x"00000000";
    constant DMEM_BASE    : word_t := x"00010000";
    constant IO_BASE      : word_t := x"80000000";

    -- IO register offsets (byte address bits [7:0])
    constant IO_LEDS     : natural := 16#00#;
    constant IO_SWITCHES : natural := 16#04#;
    constant IO_SEG7     : natural := 16#08#;
    constant IO_UART_TX  : natural := 16#0C#;
    constant IO_UART_ST  : natural := 16#10#;
    constant IO_CYCLES   : natural := 16#14#;
    constant IO_INSTRET  : natural := 16#18#;
    constant IO_TOHOST   : natural := 16#1C#;
    constant IO_BUTTONS  : natural := 16#20#;
    constant IO_STALLS   : natural := 16#24#;
    constant IO_FLUSHES  : natural := 16#28#;
    constant IO_UART_RX  : natural := 16#2C#;
    constant IO_SEG7_CTRL: natural := 16#30#;
    constant IO_BRANCHES : natural := 16#34#;
    constant IO_IRQ_PENDING : natural := 16#38#;   -- interrupt controller
    constant IO_IRQ_ENABLE  : natural := 16#3C#;
    constant IO_I2C_DATA : natural := 16#44#;   -- I2C master (temperature sensor)
    constant IO_I2C_CMD  : natural := 16#48#;
    constant IO_I2C_STAT : natural := 16#4C#;

    -- interrupt sources (bit numbers in IRQ_PENDING / IRQ_ENABLE)
    constant IRQ_UART_RX : natural := 0;   -- RX FIFO not empty (level)
    constant IRQ_RESERVED: natural := 1;   -- unused (reads 0)
    constant IRQ_BTNC    : natural := 2;   -- BTNC pressed   (sticky, write 1 to clear)
    constant IRQ_SW5     : natural := 3;   -- SW5 moved up   (sticky, write 1 to clear)
    constant IRQ_SOURCES : natural := 4;

    ---------------------------------------------------------------------------
    -- Machine-mode CSRs (privileged spec numbers)
    ---------------------------------------------------------------------------
    subtype csr_addr_t is std_logic_vector(11 downto 0);
    constant CSR_MSTATUS  : csr_addr_t := x"300";
    constant CSR_MISA     : csr_addr_t := x"301";
    constant CSR_MIE      : csr_addr_t := x"304";
    constant CSR_MTVEC    : csr_addr_t := x"305";
    constant CSR_MSCRATCH : csr_addr_t := x"340";
    constant CSR_MEPC     : csr_addr_t := x"341";
    constant CSR_MCAUSE   : csr_addr_t := x"342";
    constant CSR_MIP      : csr_addr_t := x"344";
    constant MSTATUS_MIE  : natural := 3;
    constant MSTATUS_MPIE : natural := 7;
    constant MIE_MEIE     : natural := 11;     -- machine external interrupt enable
    constant MIP_MEIP     : natural := 11;     -- machine external interrupt pending
    constant MCAUSE_MEI   : word_t := x"8000000B";  -- interrupt, cause 11
    constant MISA_RV32I   : word_t := x"40000100";  -- MXL = 32 bit, extension I

    ---------------------------------------------------------------------------
    -- Helpers
    ---------------------------------------------------------------------------
    -- Load a memory image: one 32-bit hex word (8 digits) per line, as produced
    -- by the assembler. Words after the end of the file
    -- are zero. Used for BRAM initialisation in Vivado and in simulation.
    impure function load_hex(fname : string; depth : natural) return word_array_t;

end package riscv_pkg;

package body riscv_pkg is

    -- Hex digit -> 4 bits ('0'-'9', 'a'-'f', 'A'-'F'; anything else = 0)
    function hex_nibble(c : character) return std_logic_vector is
    begin
        case c is
            when '0' => return "0000";  when '1' => return "0001";
            when '2' => return "0010";  when '3' => return "0011";
            when '4' => return "0100";  when '5' => return "0101";
            when '6' => return "0110";  when '7' => return "0111";
            when '8' => return "1000";  when '9' => return "1001";
            when 'a' | 'A' => return "1010";  when 'b' | 'B' => return "1011";
            when 'c' | 'C' => return "1100";  when 'd' | 'D' => return "1101";
            when 'e' | 'E' => return "1110";  when 'f' | 'F' => return "1111";
            when others => return "0000";
        end case;
    end function;

    -- One 8-digit hex word per line. Only bounded for-loops and the plain
    -- character read() of std.textio are used, so it works in VHDL-93 and
    -- VHDL-2008 and Vivado synthesis evaluates it (UG901: no open-ended
    -- loops, which hit Vivado's 65536-iteration limit).
    impure function load_hex(fname : string; depth : natural) return word_array_t is
        file     f   : text open read_mode is fname;
        variable l   : line;
        variable c   : character;
        variable ok  : boolean;
        variable w   : std_logic_vector(31 downto 0);
        variable mem : word_array_t(0 to depth - 1) := (others => ZERO_WORD);
    begin
        for i in 0 to depth - 1 loop
            exit when endfile(f);
            readline(f, l);
            w := (others => '0');
            for d in 7 downto 0 loop                -- 8 hex digits, MSB first
                read(l, c, ok);
                exit when not ok;
                w(4 * d + 3 downto 4 * d) := hex_nibble(c);
            end loop;
            mem(i) := w;
        end loop;
        return mem;
    end function;

end package body riscv_pkg;
