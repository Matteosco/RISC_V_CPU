-------------------------------------------------------------------------------
-- hazard_unit.vhd -- Stall / flush control
--
-- Load-use hazard: the instruction in EX is a load (op_class L) whose
-- destination is a source of the instruction in ID. Action: hold PC and
-- IF/ID for one cycle and insert a bubble into ID/EX. Only real source
-- operands are checked (uses_rs1/uses_rs2), so e.g. LUI/JAL after a load
-- never stall.
--
-- Control hazards:
--   * mispredict : a branch/jump in MEM went elsewhere than predicted
--                  (PC = ALUOutput if Cond, as in the lecture). The three
--                  younger instructions in IF/ID, ID/EX and EX are wrong
--                  path: all three are flushed (3-cycle penalty).
--   * irq_take   : interrupt taken on the instruction in EX: that
--                  instruction is cancelled, IF/ID and ID/EX are flushed.
--   * mret_take  : MRET in EX completes; IF/ID and ID/EX are flushed.
-- A flush has priority over the stall.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.riscv_pkg.all;

entity hazard_unit is
    port (
        -- instruction in ID
        id_rs1      : in  reg_addr_t;
        id_rs2      : in  reg_addr_t;
        id_uses_rs1 : in  std_logic;
        id_uses_rs2 : in  std_logic;
        -- instruction in EX
        ex_rd       : in  reg_addr_t;
        ex_is_load  : in  std_logic;   -- op_class(L)
        -- changes of the program flow
        mispredict  : in  std_logic;   -- branch/jump in MEM was mispredicted
        irq_take    : in  std_logic;   -- interrupt taken on the instruction in EX
        mret_take   : in  std_logic;   -- MRET in EX
        -- outputs
        stall_if    : out std_logic;   -- hold PC
        stall_id    : out std_logic;   -- hold IF/ID
        flush_id    : out std_logic;   -- bubble into IF/ID
        flush_ex    : out std_logic;   -- bubble into ID/EX
        flush_mem   : out std_logic    -- bubble into EX/MEM (EX cancelled)
    );
end entity hazard_unit;

architecture rtl of hazard_unit is
    signal load_use : std_logic;
    signal redirect : std_logic;
begin
    load_use <= '1' when ex_is_load = '1' and ex_rd /= "00000" and
                         ((id_uses_rs1 = '1' and id_rs1 = ex_rd) or
                          (id_uses_rs2 = '1' and id_rs2 = ex_rd))
                else '0';

    redirect <= mispredict or irq_take or mret_take;

    stall_if  <= load_use and not redirect;
    stall_id  <= load_use and not redirect;
    flush_id  <= redirect;
    flush_ex  <= redirect or load_use;
    flush_mem <= mispredict or irq_take;
end architecture rtl;
