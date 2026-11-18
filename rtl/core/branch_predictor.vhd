-------------------------------------------------------------------------------
-- branch_predictor.vhd -- Branch target buffer with 2-bit saturating counters
--
-- Lookup (IF stage, combinational): for the PC being fetched, if the table
-- holds an entry for that exact PC and its counter says "taken" (2 or 3), the
-- fetch continues at the stored target instead of PC + 4.
--
-- Update (MEM stage, when a branch/jump is resolved):
--   * entry present : counter +1 if taken, -1 if not taken (saturating 0..3);
--                     target refreshed when taken (JALR targets can change)
--   * entry missing : allocated only if the instruction was taken, with
--                     counter 2 (weakly taken) for branches, 3 for jumps
--
--   counter  0 strongly not taken   1 weakly not taken
--            2 weakly taken         3 strongly taken
--
-- Direct-mapped, 2**IDX_BITS entries, indexed by PC[IDX_BITS+1:2] and tagged
-- with the remaining PC bits, so two branches never share an entry silently.
-- With ENABLE = false it always predicts "not taken" (the original pipeline).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.riscv_pkg.all;

entity branch_predictor is
    generic (
        ENABLE   : boolean := true;
        IDX_BITS : natural := 4                 -- 16 entries
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;
        en          : in  std_logic;            -- CPU clock enable
        -- lookup (IF)
        lookup_pc   : in  word_t;
        pred_taken  : out std_logic;
        pred_target : out word_t;
        -- update (MEM)
        upd_valid   : in  std_logic;            -- a branch/jump is in MEM
        upd_pc      : in  word_t;
        upd_taken   : in  std_logic;
        upd_target  : in  word_t;
        upd_jump    : in  std_logic             -- JAL/JALR (always taken)
    );
end entity branch_predictor;

architecture rtl of branch_predictor is
    constant N       : natural := 2 ** IDX_BITS;
    constant TAG_LO  : natural := IDX_BITS + 2;
    subtype tag_t    is std_logic_vector(31 downto TAG_LO);
    type tag_arr_t   is array (0 to N - 1) of tag_t;
    type tgt_arr_t   is array (0 to N - 1) of word_t;
    type ctr_arr_t   is array (0 to N - 1) of unsigned(1 downto 0);

    signal valid  : std_logic_vector(N - 1 downto 0) := (others => '0');
    signal tags   : tag_arr_t := (others => (others => '0'));
    signal tgts   : tgt_arr_t := (others => ZERO_WORD);
    signal ctrs   : ctr_arr_t := (others => "00");

    function idx(pc : word_t) return natural is
    begin
        return to_integer(unsigned(pc(IDX_BITS + 1 downto 2)));
    end function;
begin
    ---------------------------------------------------------------------------
    -- lookup
    ---------------------------------------------------------------------------
    process (all)
        variable i : natural range 0 to N - 1;
    begin
        i := idx(lookup_pc);
        pred_target <= tgts(i);
        if ENABLE and valid(i) = '1' and tags(i) = lookup_pc(31 downto TAG_LO) and ctrs(i)(1) = '1' then
            pred_taken <= '1';
        else
            pred_taken <= '0';
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- update
    ---------------------------------------------------------------------------
    process (clk)
        variable i   : natural range 0 to N - 1;
        variable hit : boolean;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                valid <= (others => '0');
            elsif ENABLE and en = '1' and upd_valid = '1' then
                i   := idx(upd_pc);
                hit := valid(i) = '1' and tags(i) = upd_pc(31 downto TAG_LO);
                if hit then
                    if upd_taken = '1' then
                        if ctrs(i) /= "11" then ctrs(i) <= ctrs(i) + 1; end if;
                        tgts(i) <= upd_target;
                    else
                        if ctrs(i) /= "00" then ctrs(i) <= ctrs(i) - 1; end if;
                    end if;
                elsif upd_taken = '1' then
                    valid(i) <= '1';
                    tags(i)  <= upd_pc(31 downto TAG_LO);
                    tgts(i)  <= upd_target;
                    ctrs(i)  <= "11" when upd_jump = '1' else "10";
                end if;
            end if;
        end if;
    end process;
end architecture rtl;
