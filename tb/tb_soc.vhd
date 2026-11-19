-------------------------------------------------------------------------------
-- tb_soc.vhd -- System-level testbench
--
-- * Loads IMEM_FILE / DMEM_FILE into the SoC and releases reset.
-- * Decodes the UART TX line and prints every received line to the console.
-- * Waits for the program to write the TOHOST mailbox (0x8000_001C):
--     1            -> PASS
--     (n << 1) | 1 -> FAIL in test n
--   ... or for the program to stop in a jump to itself ("end: j end"):
--     HALT (any program can be run this way, no TOHOST needed)
-- * Prints cycle / instruction / stall / flush counts and the CPI.
-- * At the end prints all 32 registers (hex and signed decimal), through a
--   debug read port of the register file: the same lines come out of GHDL,
--   NVC and Vivado xsim, so the results can be compared line by line.
-- * Optional TRACE prints PC, cycle, register and value of every retired
--   instruction.
-- * RX_TEXT: text sent to the SoC's UART input after reset ('|' = LF,
--   '~' = CR), like an ESP32 would. RX_AT: cycles after reset before the
--   first character; RX_REPEAT: send the text this many times; RX_JITTER:
--   a pseudo-random pause of 0..RX_JITTER-1 cycles after every character,
--   so external interrupts land on ever different instructions. EXPECT_SEG7: the test passes when the
--   7-segment display (decoded from the real seg/an/dp pins) shows this
--   string, e.g. "  23.45 C" ('.' = decimal point of the previous digit).
-- * BTNC_AT / BTNC_EVERY: press the centre button (held for 200 cycles,
--   much longer than the simulation debounce time) to test the BTNC interrupt.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;
use work.riscv_pkg.all;

entity tb_soc is
    generic (
        IMEM_FILE    : string   := "build/test_isa.imem.hex";
        DMEM_FILE    : string   := "build/test_isa.dmem.hex";
        MAX_CYCLES   : natural  := 200_000;
        CLKS_PER_BIT : positive := 8;      -- fast UART for simulation
        TRACE        : boolean  := false;
        DBG_AUTO_STEP: boolean  := false;  -- run in debug mode, CPU enabled 1 cycle in 3
        BRANCH_PRED  : boolean  := true;   -- dynamic branch prediction in the core
        RX_TEXT      : string   := "";
        RX_AT        : natural  := 300;         -- first character this many cycles after reset
        RX_REPEAT    : positive := 1;           -- send RX_TEXT this many times
        RX_JITTER    : natural  := 0;           -- random pause 0..RX_JITTER-1 cycles between characters
        EXPECT_SEG7  : string   := "";
        SW_INIT      : natural  := 16#25C3#;    -- slide switches (SW15/SW14 must be 0)
        BTNC_AT      : natural  := 0;           -- press BTNC this many cycles after reset (0 = never)
        BTNC_EVERY   : natural  := 0;           -- ... and again every N cycles (0 = once)
        BTN_SEL      : natural  := 0;           -- which button BTNC_AT presses: 0 C, 1 U, 2 L, 3 R, 4 D
        SW5_AT       : natural  := 0;           -- move SW5 up this many cycles after reset (0 = never),
        SW5_EVERY    : natural  := 0;           -- ... down after half the period and up again every N (0 = once)
        TEMP_RAW     : natural  := 16#0C48#     -- ADT7420 model: raw temperature (0x0C48 = 24.56 C)
    );
end entity tb_soc;

architecture sim of tb_soc is
    constant CLK_PERIOD : time := 10 ns;

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal switches     : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(SW_INIT, 16));
    signal buttons      : std_logic_vector(4 downto 0)  := "00000";
    signal leds         : std_logic_vector(15 downto 0);
    signal seg          : std_logic_vector(6 downto 0);
    signal dp           : std_logic;
    signal an           : std_logic_vector(7 downto 0);
    signal uart_txd     : std_logic;
    signal uart_rxd     : std_logic := '1';
    signal tmp_scl      : std_logic;               -- I2C bus with pull-ups ('H')
    signal tmp_sda      : std_logic;
    signal seg_ok       : boolean := false;
    signal tohost_valid : std_logic;
    signal tohost_data  : word_t;
    signal dbg_pc_wb    : word_t;
    signal illegal      : std_logic;
    signal dbg_retire   : std_logic;
    signal dbg_wb_we    : std_logic;
    signal dbg_wb_rd    : std_logic_vector(4 downto 0);
    signal dbg_wb_data  : std_logic_vector(31 downto 0);
    signal regs         : word_array_t(0 to 31) := (others => (others => '0'));  -- copy of the register file
    signal dbg_stall    : std_logic;
    signal dbg_flush    : std_logic;
    signal dbg_cpu_en   : std_logic;
    signal dbg_branch   : std_logic;
    signal done         : boolean := false;
    signal halted       : boolean := false;   -- "j ." reached
    signal last_pc      : word_t := (others => '1');
    signal same_pc      : natural := 0;
    -- performance counts, measured from the core's event outputs
    signal n_cycles, n_instret, n_stalls, n_flushes, n_branches : natural := 0;


    procedure print(s : string) is
        variable l : line;
    begin
        write(l, s);
        writeline(output, l);
    end procedure;

    function hex(v : std_logic_vector) return string is
    begin
        return to_hstring(v);
    end function;

    -- "x5  t0  " : number and ABI name, fixed width so the dump lines up
    function reg_name(r : natural) return string is
        type names_t is array (0 to 31) of string(1 to 4);
        constant ABI : names_t := (
            "zero", "ra  ", "sp  ", "gp  ", "tp  ", "t0  ", "t1  ", "t2  ",
            "s0  ", "s1  ", "a0  ", "a1  ", "a2  ", "a3  ", "a4  ", "a5  ",
            "a6  ", "a7  ", "s2  ", "s3  ", "s4  ", "s5  ", "s6  ", "s7  ",
            "s8  ", "s9  ", "s10 ", "s11 ", "t3  ", "t4  ", "t5  ", "t6  ");
        variable num : string(1 to 3) := "   ";
        constant img : string := integer'image(r);
    begin
        num(1 to img'length) := img;
        return "x" & num & ABI(r);
    end function;

    -- remove leading/trailing spaces from command-line values
    function trim(s : string) return string is
        variable a : integer := s'low;
        variable z : integer := s'high;
    begin
        while a <= z and s(a) = ' ' loop a := a + 1; end loop;
        while z >= a and s(z) = ' ' loop z := z - 1; end loop;
        if a > z then return ""; end if;
        return s(a to z);
    end function;
begin

    clk <= not clk after CLK_PERIOD / 2 when not done;

    dut : entity work.soc
        generic map (
            IMEM_FILE         => IMEM_FILE,
            DMEM_FILE         => DMEM_FILE,
            CLKS_PER_BIT      => CLKS_PER_BIT,
            DEBOUNCE_CYCLES   => 4,
            STEP_TICK_CYCLES  => 3,
            BRANCH_PRED       => BRANCH_PRED,
            SEG7_REFRESH_BITS => 6)
        port map (
            clk          => clk,
            rst          => rst,
            switches     => switches,
            buttons      => buttons,
            leds         => leds,
            seg          => seg,
            dp           => dp,
            an           => an,
            uart_txd     => uart_txd,
            uart_rxd     => uart_rxd,
            led17_rgb    => open,
            tmp_scl      => tmp_scl,
            tmp_sda      => tmp_sda,
            tohost_valid => tohost_valid,
            tohost_data  => tohost_data);

    -- internal signals observed without extra ports (VHDL-2008 external names)
    dbg_pc_wb   <= << signal .tb_soc.dut.pc_wb      : word_t >>;
    dbg_retire  <= << signal .tb_soc.dut.retire     : std_logic >>;
    dbg_stall   <= << signal .tb_soc.dut.stall_evt  : std_logic >>;
    dbg_flush   <= << signal .tb_soc.dut.flush_evt  : std_logic >>;
    dbg_branch  <= << signal .tb_soc.dut.branch_evt : std_logic >>;
    dbg_cpu_en  <= << signal .tb_soc.dut.cpu_en     : std_logic >>;
    dbg_wb_we   <= << signal .tb_soc.dut.wb_we      : std_logic >>;
    dbg_wb_rd   <= << signal .tb_soc.dut.wb_rd      : std_logic_vector(4 downto 0) >>;
    dbg_wb_data <= << signal .tb_soc.dut.wb_data    : word_t >>;
    illegal     <= << signal .tb_soc.dut.u_core.illegal : std_logic >>;

    -- copy of the register file, rebuilt from the register writes in WB
    -- (dbg_wb_*): the register dump needs no read port into the hardware
    process (clk)
    begin
        if rising_edge(clk) then
            if dbg_wb_we = '1' then
                regs(to_integer(unsigned(dbg_wb_rd))) <= dbg_wb_data;
            end if;
        end if;
    end process;

    -- count the same events as the CYCLES/INSTRET/STALLS/FLUSHES registers
    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '0' and dbg_cpu_en = '1' then    -- count only CPU cycles
                n_cycles <= n_cycles + 1;
                if dbg_retire = '1' then n_instret <= n_instret + 1; end if;
                if dbg_stall  = '1' then n_stalls  <= n_stalls + 1;  end if;
                if dbg_flush  = '1' then n_flushes <= n_flushes + 1; end if;
                if dbg_branch = '1' then n_branches <= n_branches + 1; end if;
                -- halt detection: the same PC retired 3 times in a row can
                -- only be a jump to itself ("end: j end")
                if dbg_retire = '1' then
                    last_pc <= dbg_pc_wb;
                    if dbg_pc_wb = last_pc then
                        same_pc <= same_pc + 1;
                        if same_pc >= 2 then halted <= true; end if;
                    else
                        same_pc <= 0;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Main control: reset, wait for TOHOST or timeout
    ---------------------------------------------------------------------------
    process
        variable code : unsigned(31 downto 0);
        variable cpi  : real;
        variable got  : boolean := false;
        variable by_halt : boolean := false;   -- stopped by "j ." (not by TOHOST)
        variable n_cyc, n_ins, n_stl, n_fls, n_br : natural := 0;
    begin
        print("[tb] IMEM = " & IMEM_FILE);
        if DBG_AUTO_STEP then
            print("[tb] debug mode: SW15 = SW14 = 1, CPU advances 1 cycle in 3");
            switches(15 downto 14) <= "11";
        end if;
        rst <= '1';
        wait for 5 * CLK_PERIOD;
        wait until rising_edge(clk);
        rst <= '0';

        for i in 0 to MAX_CYCLES loop
            wait until rising_edge(clk);
            if tohost_valid = '1' or halted or (EXPECT_SEG7'length > 0 and seg_ok) then
                got := true;
                by_halt := halted and tohost_valid /= '1' and not seg_ok;
                exit;
            end if;
        end loop;

        -- snapshot the counters when the program reports its result
        code  := unsigned(tohost_data);
        n_cyc := n_cycles;
        n_ins := n_instret;
        n_stl := n_stalls;
        n_fls := n_flushes;
        n_br  := n_branches;

        -- give the UART time to drain the FIFO
        for i in 0 to 20 * 10 * CLKS_PER_BIT loop
            wait until rising_edge(clk);
        end loop;

        print("[tb] ------------------------------------------------");
        print("[tb] cycles   : " & integer'image(n_cyc));
        print("[tb] instret  : " & integer'image(n_ins));
        print("[tb] stalls   : " & integer'image(n_stl) & "  (load-use bubbles)");
        print("[tb] flushes  : " & integer'image(n_fls) & "  (mispredicted branches/jumps, 3 bubbles each)");
        if n_br > 0 then
            print("[tb] branches : " & integer'image(n_br) & "  (branch prediction " &
                  boolean'image(BRANCH_PRED) & ", " & integer'image(100 * (n_br - n_fls) / n_br) & " % predicted correctly)");
        end if;
        if n_ins > 0 then
            cpi := real(n_cyc) / real(n_ins);
            print("[tb] CPI      : " & real'image(cpi));
        end if;
        print("[tb] ------------------------------------------------");
        -- register dump (the program is stopped in a loop, values are final)
        print("[tb] registers at the end of the program:");
        for r in 0 to 31 loop
            print("[reg] " & reg_name(r) & " = 0x" & hex(regs(r)) & "  ("
                  & integer'image(to_integer(signed(regs(r)))) & ")");
        end loop;
        print("[tb] ------------------------------------------------");
        if not got then
            print("[tb] TIMEOUT after " & integer'image(MAX_CYCLES) & " cycles");
            done <= true;
            assert false report "TIMEOUT" severity failure;
        elsif EXPECT_SEG7'length > 0 then
            print("[tb] display shows '" & EXPECT_SEG7 & "'");
            print("[tb] PASS");
            done <= true;
            finish;
        elsif by_halt then
            print("[tb] HALT (program stopped in a jump to itself)");
            done <= true;
            finish;
        elsif code = 1 then
            print("[tb] PASS");
            done <= true;
            finish;
        else
            print("[tb] FAIL in test " & integer'image(to_integer(code srl 1)));
            done <= true;
            assert false report "FAIL" severity failure;
        end if;
        wait;
    end process;

    ---------------------------------------------------------------------------
    -- UART receiver model: prints each received line
    ---------------------------------------------------------------------------
    process
        variable buf : line;
        variable b   : std_logic_vector(7 downto 0);
    begin
        wait until rst = '0';
        loop
            wait until falling_edge(uart_txd);               -- start bit
            for i in 1 to CLKS_PER_BIT + CLKS_PER_BIT / 2 loop -- middle of bit 0
                wait until rising_edge(clk);
            end loop;
            for i in 0 to 7 loop
                b(i) := uart_txd;
                for j in 1 to CLKS_PER_BIT loop
                    wait until rising_edge(clk);
                end loop;
            end loop;
            if b = x"0A" then
                if buf = null then
                    write(output, string'("[uart] ") & LF);
                else
                    write(output, "[uart] " & buf.all & LF);
                    deallocate(buf);
                end if;
            elsif b /= x"0D" then
                write(buf, character'val(to_integer(unsigned(b))));
            end if;
        end loop;
    end process;

    ---------------------------------------------------------------------------
    -- BTNC presses (interrupt tests)
    process
    begin
        if BTNC_AT = 0 then
            wait;
        end if;
        wait until falling_edge(rst);
        for i in 1 to BTNC_AT loop
            wait until rising_edge(clk);
        end loop;
        loop
            buttons(BTN_SEL) <= '1';
            for i in 1 to 200 loop wait until rising_edge(clk); end loop;
            buttons(BTN_SEL) <= '0';
            exit when BTNC_EVERY = 0;
            for i in 201 to BTNC_EVERY loop wait until rising_edge(clk); end loop;
        end loop;
        wait;
    end process;

    -- SW5 moved up / down (switch interrupt)
    process
    begin
        if SW5_AT = 0 then
            wait;
        end if;
        wait until falling_edge(rst);
        for i in 1 to SW5_AT loop wait until rising_edge(clk); end loop;
        loop
            switches(5) <= '1';
            exit when SW5_EVERY = 0;
            for i in 1 to SW5_EVERY / 2 loop wait until rising_edge(clk); end loop;
            switches(5) <= '0';
            for i in SW5_EVERY / 2 + 1 to SW5_EVERY loop wait until rising_edge(clk); end loop;
        end loop;
        wait;
    end process;

    -- ADT7420 temperature sensor on the I2C bus (pull-up resistors = 'H')
    tmp_scl <= 'H';
    tmp_sda <= 'H';
    u_temp_sensor : entity work.adt7420_model
        generic map (TEMP_RAW => std_logic_vector(to_unsigned(TEMP_RAW, 16)))
        port map (scl => tmp_scl, sda => tmp_sda);

    -- every transfer is checked against the I2C specification (UM10204,
    -- Table 11, Standard-mode); a violation stops the simulation
    u_i2c_check : entity work.i2c_timing_check
        generic map (CLK_SIM => CLK_PERIOD, CLK_BOARD => 20 ns)
        port map (scl => tmp_scl, sda => tmp_sda);

    -- UART sender model (e.g. the ESP32): transmits RX_TEXT after reset
    ---------------------------------------------------------------------------
    process
        variable ch   : character;
        variable b    : std_logic_vector(7 downto 0);
        variable seed : natural := 1;           -- pseudo-random pauses (ZX81 generator)
    begin
        uart_rxd <= '1';
        wait until rst = '0';
        for i in 1 to RX_AT loop wait until rising_edge(clk); end loop;
        for r in 1 to RX_REPEAT loop
        for k in RX_TEXT'range loop
            ch := RX_TEXT(k);
            if ch = '|' then ch := LF; elsif ch = '~' then ch := CR; end if;
            b := std_logic_vector(to_unsigned(character'pos(ch), 8));
            uart_rxd <= '0';
            for j in 1 to CLKS_PER_BIT loop wait until rising_edge(clk); end loop;
            for i in 0 to 7 loop
                uart_rxd <= b(i);
                for j in 1 to CLKS_PER_BIT loop wait until rising_edge(clk); end loop;
            end loop;
            uart_rxd <= '1';
            for j in 1 to 2 * CLKS_PER_BIT loop wait until rising_edge(clk); end loop;
            if RX_JITTER > 0 then
                seed := (seed * 75 + 74) mod 65537;
                for j in 1 to seed mod RX_JITTER loop wait until rising_edge(clk); end loop;
            end if;
        end loop;
        end loop;
        wait;
    end process;

    ---------------------------------------------------------------------------
    -- 7-segment decoder: rebuilds the displayed text from seg/an/dp
    ---------------------------------------------------------------------------
    process (clk)
        type pat_t is array (0 to 15) of std_logic_vector(6 downto 0);
        constant PAT : pat_t := (
            "1000000", "1111001", "0100100", "0110000", "0011001", "0010010",
            "0000010", "1111000", "0000000", "0010000", "0001000", "0000011",
            "1000110", "0100001", "0000110", "0001110");
        constant HEXC : string(1 to 16) := "0123456789AbCdEF";
        type chars_t is array (0 to 7) of character;
        variable chr   : chars_t := (others => ' ');
        variable dot   : std_logic_vector(7 downto 0) := (others => '0');
        variable cnt   : natural := 0;
        variable shown : line;
        variable l     : line;
    begin
        if rising_edge(clk) then
            for k in 0 to 7 loop
                if an(k) = '0' then
                    chr(k) := '?';
                    for d in 0 to 15 loop
                        if seg = PAT(d) then chr(k) := HEXC(d + 1); end if;
                    end loop;
                    if dp = '0' then dot(k) := '1'; end if;
                end if;
            end loop;
            cnt := cnt + 1;
            if cnt = 64 then                   -- one full scan of the 8 digits
                cnt := 0;
                l := null;
                for k in 7 downto 0 loop
                    write(l, chr(k));
                    if dot(k) = '1' then write(l, '.'); end if;
                end loop;
                if shown = null or l.all /= shown.all then
                    if EXPECT_SEG7'length > 0 then
                        print("[seg7] '" & l.all & "'");
                    end if;
                    deallocate(shown);
                    shown := new string'(l.all);
                end if;
                seg_ok <= EXPECT_SEG7'length > 0 and trim(l.all) = trim(EXPECT_SEG7);
                deallocate(l);
                chr := (others => ' ');
                dot := (others => '0');
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Monitors
    ---------------------------------------------------------------------------
    process (clk)
        variable l : line;
    begin
        if rising_edge(clk) then
            if illegal = '1' then
                report "illegal instruction reached EX" severity warning;
            end if;
            if TRACE and dbg_retire = '1' then
                -- cycle = CPU cycles since reset (as the CYCLES counter);
                -- rd/val only when the instruction writes a register
                write(l, string'("[trace] retire pc=0x") & hex(dbg_pc_wb)
                         & " cycle=" & integer'image(n_cycles));
                if dbg_wb_we = '1' then
                    write(l, " rd=" & integer'image(to_integer(unsigned(dbg_wb_rd)))
                             & " val=0x" & hex(dbg_wb_data));
                end if;
                writeline(output, l);
            end if;
        end if;
    end process;

end architecture sim;
