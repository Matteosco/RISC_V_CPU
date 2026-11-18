-------------------------------------------------------------------------------
-- io_ctrl.vhd -- Memory-mapped peripheral block at 0x8000_0000
--
--  Offset  Name       Access  Description
--  0x00    LEDS       R/W     16 user LEDs
--  0x04    SWITCHES   R       16 slide switches (synchronised)
--  0x08    SEG7       R/W     32-bit value shown as 8 hex digits
--  0x0C    UART_TX    W       push byte [7:0] into 16-entry TX FIFO
--  0x10    UART_STAT  R       bit0 TX FIFO full, bit1 TX idle, bit2 TX FIFO empty,
--                             bit3 RX byte available, bit4 RX FIFO full
--  0x14    CYCLES     R       clock cycles since reset
--  0x18    INSTRET    R       instructions retired since reset
--  0x1C    TOHOST     W       simulation pass/fail mailbox (1 = pass)
--  0x20    BUTTONS    R       5 push buttons (debounced, see debouncer.vhd)
--  0x24    STALLS     R       load-use stall cycles
--  0x28    FLUSHES    R       mispredicted branches/jumps (each costs 3 cycles)
--  0x2C    UART_RX    R       bit8 = byte valid, bits7..0 = byte; reading
--                             removes the byte from the 16-entry RX FIFO
--  0x30    SEG7_CTRL  R/W     bits7..0 digit on (1 = shown, reset 0xFF),
--                             bits15..8 decimal point on (reset 0x00)
--  0x34    BRANCHES   R       branches/jumps executed (prediction accuracy =
--                             1 - FLUSHES / BRANCHES)
--  0x38    IRQ_PENDING R/W1C  interrupt sources waiting:
--                             bit0 UART RX byte available (level: clears
--                                  when the RX FIFO is empty)
--                             bit1 reserved (reads 0)
--                             bit2 BTNC pressed          (write 1 to clear)
--                             bit3 SW5 moved up          (write 1 to clear)
--  0x3C    IRQ_ENABLE R/W     same bits: 1 = the source may interrupt
--  0x44    I2C_DATA   R/W     W: byte to send; R: last byte received
--  0x48    I2C_CMD    W       start a command (ignored while busy):
--                             bit0 START  bit1 WRITE  bit2 READ  bit3 STOP
--                             bit4 NACK after READ (last byte)
--  0x4C    I2C_STAT   R       bit0 busy, bit1 NACK (slave did not acknowledge)
--          (I2C master at 100 kHz on the bus of the ADT7420 temperature sensor)
--
-- Interrupt controller: irq = OR(IRQ_PENDING and IRQ_ENABLE). It drives the
-- core's machine external interrupt (mip.MEIP); the core takes it when
-- mstatus.MIE and mie.MEIE are set.
--
-- Read data is registered, matching the one-cycle latency of the BRAMs.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.riscv_pkg.all;

entity io_ctrl is
    generic (
        CLKS_PER_BIT    : positive := 434;
        DEBOUNCE_CYCLES : positive := 500_000;  -- 10 ms at 50 MHz
        I2C_QUARTER     : positive := 125       -- I2C: f_clk / (4 x 100 kHz)
    );
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;
        -- bus (sampled in the same cycle as the memories)
        sel          : in  std_logic;
        addr         : in  std_logic_vector(7 downto 0);
        we           : in  std_logic;
        re           : in  std_logic := '0';   -- load in progress (pops UART_RX)
        be           : in  std_logic_vector(3 downto 0);
        wdata        : in  word_t;
        rdata        : out word_t;
        -- core events
        retire       : in  std_logic;
        stall_evt    : in  std_logic;
        flush_evt    : in  std_logic;
        branch_evt   : in  std_logic := '0';
        cpu_en       : in  std_logic := '1';   -- CPU clock enable (single-step)
        irq          : out std_logic;          -- interrupt request to the core
        -- board I/O
        switches     : in  std_logic_vector(15 downto 0);
        buttons      : in  std_logic_vector(4 downto 0);
        buttons_clean: out std_logic_vector(4 downto 0);   -- debounced copy
        leds         : out std_logic_vector(15 downto 0);
        seg7_value   : out word_t;
        seg7_ctrl    : out std_logic_vector(15 downto 0);  -- dp(15..8) & enable(7..0)
        uart_txd     : out std_logic;
        uart_rxd     : in  std_logic := '1';
        i2c_scl_o    : out std_logic;           -- '0' = pull the line low
        i2c_sda_o    : out std_logic;
        i2c_scl_i    : in  std_logic := '1';
        i2c_sda_i    : in  std_logic := '1';
        -- simulation mailbox
        tohost_valid : out std_logic;
        tohost_data  : out word_t;
        -- debug (ILA): UART receiver and interrupt controller, bit by bit
        --   0 RX line  2..1 rx state  5..3 bit number  13..6 shift register
        --   14 byte valid  15 RX FIFO empty  16 FIFO read (pop)
        --   20..17 IRQ_PENDING  24..21 IRQ_ENABLE  25 irq line
        dbg_io       : out std_logic_vector(25 downto 0)
    );
end entity io_ctrl;

architecture rtl of io_ctrl is
    signal leds_r     : std_logic_vector(15 downto 0) := (others => '0');
    signal seg7_r     : word_t := ZERO_WORD;
    signal seg7_ctrl_r: std_logic_vector(15 downto 0) := x"00FF";
    signal sw_s1, sw_s2   : std_logic_vector(15 downto 0) := (others => '0');
    signal btn_clean      : std_logic_vector(4 downto 0);
    signal cycles     : unsigned(31 downto 0) := (others => '0');
    signal instret    : unsigned(31 downto 0) := (others => '0');
    signal stalls     : unsigned(31 downto 0) := (others => '0');
    signal flushes    : unsigned(31 downto 0) := (others => '0');
    signal branches   : unsigned(31 downto 0) := (others => '0');

    -- interrupt controller
    signal irq_pend   : std_logic_vector(IRQ_SOURCES - 1 downto 0);
    signal irq_sticky : std_logic_vector(IRQ_SOURCES - 1 downto 0) := (others => '0');
    signal irq_en     : std_logic_vector(IRQ_SOURCES - 1 downto 0) := (others => '0');
    signal btnc_prev  : std_logic := '0';
    signal sw5_clean  : std_logic_vector(0 downto 0);   -- SW5 debounced
    signal sw5_prev   : std_logic := '0';

    signal fifo_wr, fifo_rd, fifo_empty, fifo_full : std_logic;
    signal fifo_dout : std_logic_vector(7 downto 0);
    signal tx_busy   : std_logic;
    signal rx_byte   : std_logic_vector(7 downto 0);
    signal rx_valid  : std_logic;
    signal dbg_rx_line  : std_logic;
    signal dbg_rx_state : std_logic_vector(1 downto 0);
    signal dbg_rx_bit   : std_logic_vector(2 downto 0);
    signal irq_int      : std_logic;
    signal rxf_rd, rxf_empty, rxf_full : std_logic;
    signal rxf_dout  : std_logic_vector(7 downto 0);
    signal wr, rd    : std_logic;
    signal i2c_tx    : std_logic_vector(7 downto 0) := (others => '0');
    signal i2c_rx    : std_logic_vector(7 downto 0);
    signal i2c_go    : std_logic;
    signal i2c_busy, i2c_nack : std_logic;
    signal off       : natural range 0 to 255;

    -- apply byte enables to a register
    function merge(old : word_t; new_v : word_t; strb : std_logic_vector(3 downto 0))
        return word_t is
        variable r : word_t := old;
    begin
        for i in 0 to 3 loop
            if strb(i) = '1' then
                r(8 * i + 7 downto 8 * i) := new_v(8 * i + 7 downto 8 * i);
            end if;
        end loop;
        return r;
    end function;
begin
    wr  <= sel and we;
    rd  <= sel and re;
    off <= to_integer(unsigned(addr));

    process (clk)
        variable tmp : word_t;
    begin
        if rising_edge(clk) then
            -- input synchronisers
            sw_s1  <= switches;  sw_s2  <= sw_s1;

            tohost_valid <= '0';

            if rst = '1' then
                leds_r  <= (others => '0');
                seg7_r  <= ZERO_WORD;
                seg7_ctrl_r <= x"00FF";
                cycles  <= (others => '0');
                instret <= (others => '0');
                stalls  <= (others => '0');
                flushes <= (others => '0');
                branches <= (others => '0');
                irq_sticky <= (others => '0');
                irq_en     <= (others => '0');
                btnc_prev  <= '0';
                sw5_prev   <= sw5_clean(0);   -- a switch already up is not an event
            else
                if cpu_en = '1' then cycles <= cycles + 1; end if;
                if retire = '1'    then instret <= instret + 1; end if;
                if stall_evt = '1' then stalls  <= stalls + 1;  end if;
                if flush_evt = '1' then flushes <= flushes + 1; end if;
                if branch_evt = '1' then branches <= branches + 1; end if;

                if wr = '1' then
                    case off is
                        when IO_LEDS =>
                            tmp    := merge(x"0000" & leds_r, wdata, be);
                            leds_r <= tmp(15 downto 0);
                        when IO_SEG7 =>
                            seg7_r <= merge(seg7_r, wdata, be);
                        when IO_SEG7_CTRL =>
                            tmp         := merge(x"0000" & seg7_ctrl_r, wdata, be);
                            seg7_ctrl_r <= tmp(15 downto 0);
                        when IO_TOHOST =>
                            tohost_valid <= '1';
                            tohost_data  <= wdata;
                        when IO_IRQ_PENDING =>      -- write 1 to clear
                            if be(0) = '1' then
                                irq_sticky(IRQ_BTNC)  <= irq_sticky(IRQ_BTNC)  and not wdata(IRQ_BTNC);
                                irq_sticky(IRQ_SW5)   <= irq_sticky(IRQ_SW5)   and not wdata(IRQ_SW5);
                            end if;
                        when IO_IRQ_ENABLE =>
                            if be(0) = '1' then
                                irq_en <= wdata(IRQ_SOURCES - 1 downto 0);
                            end if;
                        when IO_I2C_DATA =>
                            if be(0) = '1' then i2c_tx <= wdata(7 downto 0); end if;
                        when others => null;
                    end case;
                end if;

                -- interrupt sources (after the bus write, so that an event in
                -- the same cycle as a write-1-to-clear is not lost) ---------
                -- BTNC: rising edge of the debounced button
                btnc_prev <= btn_clean(0);
                if btn_clean(0) = '1' and btnc_prev = '0' then
                    irq_sticky(IRQ_BTNC) <= '1';
                end if;
                -- SW5: rising edge of the debounced switch (moved up)
                sw5_prev <= sw5_clean(0);
                if sw5_clean(0) = '1' and sw5_prev = '0' then
                    irq_sticky(IRQ_SW5) <= '1';
                end if;

            end if;

            -- registered read (held while the CPU is frozen, like the BRAM)
            if cpu_en = '1' then
            case off is
                when IO_LEDS     => rdata <= x"0000" & leds_r;
                when IO_SWITCHES => rdata <= x"0000" & sw_s2;
                when IO_SEG7     => rdata <= seg7_r;
                when IO_UART_ST  =>
                    rdata <= (0 => fifo_full,
                              1 => fifo_empty and not tx_busy,
                              2 => fifo_empty,
                              3 => not rxf_empty,
                              4 => rxf_full,
                              others => '0');
                when IO_UART_RX  => rdata <= (31 downto 9 => '0') & (not rxf_empty) & rxf_dout;
                when IO_SEG7_CTRL=> rdata <= x"0000" & seg7_ctrl_r;
                when IO_CYCLES   => rdata <= std_logic_vector(cycles);
                when IO_INSTRET  => rdata <= std_logic_vector(instret);
                when IO_BUTTONS  => rdata <= (31 downto 5 => '0') & btn_clean;
                when IO_STALLS   => rdata <= std_logic_vector(stalls);
                when IO_FLUSHES  => rdata <= std_logic_vector(flushes);
                when IO_BRANCHES => rdata <= std_logic_vector(branches);
                when IO_IRQ_PENDING => rdata <= (31 downto IRQ_SOURCES => '0') & irq_pend;
                when IO_IRQ_ENABLE  => rdata <= (31 downto IRQ_SOURCES => '0') & irq_en;
                when IO_I2C_DATA => rdata <= x"000000" & i2c_rx;
                when IO_I2C_STAT => rdata <= (0 => i2c_busy, 1 => i2c_nack, others => '0');
                when others      => rdata <= ZERO_WORD;
            end case;
            end if;
        end if;
    end process;

    leds       <= leds_r;
    seg7_value <= seg7_r;
    seg7_ctrl  <= seg7_ctrl_r;

    -- interrupt controller output
    irq_pend <= (IRQ_UART_RX => not rxf_empty,
                 IRQ_RESERVED => '0',
                 IRQ_BTNC    => irq_sticky(IRQ_BTNC),
                 IRQ_SW5     => irq_sticky(IRQ_SW5));
    irq_int <= '1' when (irq_pend and irq_en) /= (irq_pend'range => '0') else '0';
    irq     <= irq_int;

    ---------------------------------------------------------------------------
    -- Push buttons: synchroniser + debouncer
    ---------------------------------------------------------------------------
    u_btn_debounce : entity work.debouncer
        generic map (WIDTH => 5, STABLE_CYCLES => DEBOUNCE_CYCLES)
        port map (clk => clk, rst => rst, din => buttons, dout => btn_clean);

    buttons_clean <= btn_clean;

    -- SW5 as an interrupt source: a slide switch bounces too
    u_sw5_debounce : entity work.debouncer
        generic map (WIDTH => 1, STABLE_CYCLES => DEBOUNCE_CYCLES)
        port map (clk => clk, rst => rst, din => switches(5 downto 5), dout => sw5_clean);

    ---------------------------------------------------------------------------
    -- UART transmitter with FIFO buffer
    ---------------------------------------------------------------------------
    fifo_wr <= '1' when wr = '1' and off = IO_UART_TX and be(0) = '1' else '0';
    fifo_rd <= not fifo_empty and not tx_busy;

    u_fifo : entity work.sync_fifo
        generic map (WIDTH => 8, DEPTH_BITS => 4)
        port map (
            clk => clk, rst => rst,
            wr_en => fifo_wr, wdata => wdata(7 downto 0),
            rd_en => fifo_rd, rdata => fifo_dout,
            empty => fifo_empty, full => fifo_full);

    ---------------------------------------------------------------------------
    -- UART receiver with FIFO buffer (e.g. an ESP32 on Pmod JA1)
    ---------------------------------------------------------------------------
    u_uart_rx : entity work.uart_rx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (clk => clk, rst => rst, rx => uart_rxd,
                  data => rx_byte, valid => rx_valid, frame_err => open,
                  dbg_rx => dbg_rx_line, dbg_state => dbg_rx_state, dbg_bit => dbg_rx_bit);

    dbg_io <= irq_int & irq_en & irq_pend & rxf_rd & rxf_empty & rx_valid
            & rx_byte & dbg_rx_bit & dbg_rx_state & dbg_rx_line;

    -- a load from UART_RX takes the oldest byte out of the FIFO
    rxf_rd <= '1' when rd = '1' and off = IO_UART_RX and cpu_en = '1' and rxf_empty = '0' else '0';

    u_rx_fifo : entity work.sync_fifo
        generic map (WIDTH => 8, DEPTH_BITS => 4)
        port map (
            clk => clk, rst => rst,
            wr_en => rx_valid, wdata => rx_byte,
            rd_en => rxf_rd, rdata => rxf_dout,
            empty => rxf_empty, full => rxf_full);

    ---------------------------------------------------------------------------
    -- I2C master (ADT7420 temperature sensor)
    ---------------------------------------------------------------------------
    i2c_go <= '1' when wr = '1' and off = IO_I2C_CMD and be(0) = '1' else '0';

    u_i2c : entity work.i2c_master
        generic map (QUARTER => I2C_QUARTER)
        port map (
            clk => clk, rst => rst,
            cmd_valid => i2c_go, cmd => wdata(4 downto 0), tx_byte => i2c_tx,
            rx_byte => i2c_rx, busy => i2c_busy, nack => i2c_nack,
            scl_o => i2c_scl_o, sda_o => i2c_sda_o,
            scl_i => i2c_scl_i, sda_i => i2c_sda_i);

    u_uart : entity work.uart_tx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (
            clk => clk, rst => rst,
            start => fifo_rd, data => fifo_dout,
            busy => tx_busy, tx => uart_txd);
end architecture rtl;
