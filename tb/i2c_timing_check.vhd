-------------------------------------------------------------------------------
-- i2c_timing_check.vhd -- checks the I2C bus against the Standard-mode timing
--                         of the NXP I2C-bus specification UM10204 rev. 7.0,
--                         Table 11 (simulation only)
--
--   fSCL     <= 100 kHz      (SCL period >= 10 us)
--   tLOW     >= 4.7 us       SCL low
--   tHIGH    >= 4.0 us       SCL high
--   tSU;STA  >= 4.7 us       SCL rise -> (repeated) START
--   tHD;STA  >= 4.0 us       START -> first SCL fall
--   tSU;DAT  >= 250 ns       SDA change -> SCL rise
--   tSU;STO  >= 4.0 us       SCL rise -> STOP
--   tBUF     >= 4.7 us       STOP -> next START
--
-- The testbench clock is faster than the board clock, so durations are
-- scaled by CLK_BOARD / CLK_SIM to get the real times on the FPGA.
-- A violation stops the simulation (severity failure), so the test fails.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity i2c_timing_check is
    generic (
        CLK_SIM   : time := 10 ns;      -- clock period in the testbench
        CLK_BOARD : time := 20 ns       -- clock period on the board (50 MHz)
    );
    port (
        scl : in std_logic;
        sda : in std_logic
    );
end entity i2c_timing_check;

architecture sim of i2c_timing_check is
begin
    process
        constant SCALE : natural := CLK_BOARD / CLK_SIM;
        variable t_scl_rise, t_scl_fall, t_sda_chg : time := 0 ns;
        variable t_start, t_stop, t_prev_rise      : time := 0 ns;
        variable have_stop, in_tx, start_in_high   : boolean := false;
        variable scl_q, sda_q, scl_n, sda_n        : std_logic := '1';
        variable n_start, n_stop                   : natural := 0;

        procedure check(ok : boolean; what : string; dt : time; min : time) is
        begin
            assert ok
                report "I2C TIMING VIOLATION (UM10204 Table 11, Standard-mode): " & what &
                       " = " & integer'image((dt * SCALE) / 1 ns) & " ns < " &
                       integer'image(min / 1 ns) & " ns"
                severity failure;
        end procedure;
    begin
        wait on scl, sda;
        scl_n := to_X01(scl);
        sda_n := to_X01(sda);

        -- SDA changes while SCL is high: START or STOP
        if scl_n = '1' and scl_q = '1' and sda_n /= sda_q then
            if sda_n = '0' then                                   -- START
                check((now - t_scl_rise) * SCALE >= 4.7 us, "tSU;STA", now - t_scl_rise, 4.7 us);
                if have_stop then
                    check((now - t_stop) * SCALE >= 4.7 us, "tBUF", now - t_stop, 4.7 us);
                end if;
                t_start := now; start_in_high := true; in_tx := true;
                n_start := n_start + 1;
            else                                                  -- STOP
                check((now - t_scl_rise) * SCALE >= 4.0 us, "tSU;STO", now - t_scl_rise, 4.0 us);
                t_stop := now; have_stop := true; in_tx := false;
                n_stop := n_stop + 1;
            end if;
        elsif sda_n /= sda_q then
            t_sda_chg := now;                                     -- data change (SCL low)
        end if;

        if scl_n = '1' and scl_q = '0' then                       -- SCL rises
            if in_tx then
                check((now - t_scl_fall) * SCALE >= 4.7 us, "tLOW", now - t_scl_fall, 4.7 us);
                check((now - t_prev_rise) * SCALE >= 10 us, "SCL period (fSCL)", now - t_prev_rise, 10 us);
                if t_sda_chg > t_scl_fall then
                    check((now - t_sda_chg) * SCALE >= 250 ns, "tSU;DAT", now - t_sda_chg, 250 ns);
                end if;
            end if;
            t_scl_rise := now; t_prev_rise := now; start_in_high := false;
        elsif scl_n = '0' and scl_q = '1' then                    -- SCL falls
            if start_in_high then
                check((now - t_start) * SCALE >= 4.0 us, "tHD;STA", now - t_start, 4.0 us);
            end if;
            if in_tx then
                check((now - t_scl_rise) * SCALE >= 4.0 us, "tHIGH", now - t_scl_rise, 4.0 us);
            end if;
            t_scl_fall := now; start_in_high := false;
        end if;

        scl_q := scl_n;
        sda_q := sda_n;
    end process;
end architecture sim;
