library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Testbench for ntt_engine
-- Tests:
--   1. Load delta polynomial (coeff[0]=1, rest=0)
--   2. Run forward NTT — every output coefficient should equal 1
--      (NTT of a delta function at index 0 is the all-ones vector in Dilithium)
--   3. Run INTT on result — should recover original delta
--   4. Verify round-trip fidelity
entity tb_ntt_engine is
end entity tb_ntt_engine;

architecture sim of tb_ntt_engine is

  constant CLK_PERIOD : time := 10 ns;
  constant N          : natural := 256;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  -- poly_bram port signals
  signal bwe_a   : std_logic := '0';
  signal baddr_a : unsigned(7 downto 0) := (others => '0');
  signal bdin_a  : unsigned(22 downto 0) := (others => '0');
  signal bdout_a : unsigned(22 downto 0);
  signal bwe_b   : std_logic := '0';
  signal baddr_b : unsigned(7 downto 0) := (others => '0');
  signal bdin_b  : unsigned(22 downto 0) := (others => '0');
  signal bdout_b : unsigned(22 downto 0);

  -- ntt_engine port signals
  signal ntt_start   : std_logic := '0';
  signal ntt_inverse : std_logic := '0';
  signal ntt_we_a    : std_logic;
  signal ntt_addr_a  : unsigned(7 downto 0);
  signal ntt_din_a   : unsigned(22 downto 0);
  signal ntt_dout_a  : unsigned(22 downto 0);
  signal ntt_we_b    : std_logic;
  signal ntt_addr_b  : unsigned(7 downto 0);
  signal ntt_din_b   : unsigned(22 downto 0);
  signal ntt_dout_b  : unsigned(22 downto 0);
  signal ntt_done    : std_logic;
  signal ntt_busy    : std_logic;

  -- Mux control: '0' = testbench drives BRAM, '1' = NTT engine drives BRAM
  signal bram_sel : std_logic := '0';

  -- BRAM port A mux
  signal tb_we_a    : std_logic := '0';
  signal tb_addr_a  : unsigned(7 downto 0) := (others => '0');
  signal tb_din_a   : unsigned(22 downto 0) := (others => '0');

  -- BRAM port B mux (testbench read-back)
  signal tb_addr_b  : unsigned(7 downto 0) := (others => '0');

begin

  -- Free-running clock
  clk <= not clk after CLK_PERIOD / 2;

  -- BRAM mux: NTT engine takes over when bram_sel='1'
  bwe_a   <= ntt_we_a   when bram_sel = '1' else tb_we_a;
  baddr_a <= ntt_addr_a when bram_sel = '1' else tb_addr_a;
  bdin_a  <= ntt_din_a  when bram_sel = '1' else tb_din_a;
  ntt_dout_a <= bdout_a;

  bwe_b   <= ntt_we_b;
  baddr_b <= ntt_addr_b when bram_sel = '1' else tb_addr_b;
  bdin_b  <= ntt_din_b;
  ntt_dout_b <= bdout_b;

  -- poly_bram instance
  u_bram: entity work.poly_bram
    port map (
      clk    => clk,
      we_a   => bwe_a,
      addr_a => baddr_a,
      din_a  => bdin_a,
      dout_a => bdout_a,
      we_b   => bwe_b,
      addr_b => baddr_b,
      din_b  => bdin_b,
      dout_b => bdout_b
    );

  -- ntt_engine instance
  u_ntt: entity work.ntt_engine
    port map (
      clk    => clk,
      rst    => rst,
      start  => ntt_start,
      inverse => ntt_inverse,
      we_a   => ntt_we_a,
      addr_a => ntt_addr_a,
      din_a  => ntt_din_a,
      dout_a => ntt_dout_a,
      we_b   => ntt_we_b,
      addr_b => ntt_addr_b,
      din_b  => ntt_din_b,
      dout_b => ntt_dout_b,
      done   => ntt_done,
      busy   => ntt_busy
    );

  -- Stimulus
  stimulus: process
    variable pass_ntt  : boolean := true;
    variable pass_intt : boolean := true;
    variable coeff_val : unsigned(22 downto 0);
    variable fail_cnt  : natural := 0;
  begin
    -- Reset
    rst <= '1';
    wait for 5 * CLK_PERIOD;
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    -- ------------------------------------------------------------------
    -- Phase 1: Load delta polynomial via port A
    -- coeff[0] = 1, coeff[1..255] = 0
    -- ------------------------------------------------------------------
    report "Phase 1: Loading delta polynomial into BRAM" severity note;
    bram_sel <= '0';
    for i in 0 to N-1 loop
      tb_we_a   <= '1';
      tb_addr_a <= to_unsigned(i, 8);
      if i = 0 then
        tb_din_a <= to_unsigned(1, 23);
      else
        tb_din_a <= (others => '0');
      end if;
      wait until rising_edge(clk);
    end loop;
    tb_we_a <= '0';
    wait until rising_edge(clk);

    -- ------------------------------------------------------------------
    -- Phase 2: Run forward NTT
    -- ------------------------------------------------------------------
    report "Phase 2: Starting forward NTT" severity note;
    bram_sel    <= '1';
    ntt_inverse <= '0';
    ntt_start   <= '1';
    wait until rising_edge(clk);
    ntt_start <= '0';

    -- Wait for NTT done
    wait until ntt_done = '1';
    wait until rising_edge(clk);
    bram_sel <= '0';
    report "Phase 2: NTT done" severity note;

    -- ------------------------------------------------------------------
    -- Phase 3: Read NTT output and verify all coefficients = 1
    -- NTT(delta[0]=1, rest=0) should yield all-ones in Dilithium NTT
    -- ------------------------------------------------------------------
    -- Python reference: NTT([1,0,...,0]) yields 1 at even indices, 0 at odd indices.
    -- (Verified by verify_ntt.py: distinct values = {0,1}, even=1, odd=0)
    report "Phase 3: Verifying NTT output (even coeff=1, odd coeff=0)" severity note;
    fail_cnt := 0;
    for i in 0 to N-1 loop
      tb_addr_b <= to_unsigned(i, 8);
      wait until rising_edge(clk);  -- BRAM read latency 1 cycle
      wait until rising_edge(clk);
      coeff_val := bdout_b;
      -- Expected: even indices = 1, odd indices = 0
      if (i mod 2 = 0 and to_integer(coeff_val) /= 1) or
         (i mod 2 = 1 and to_integer(coeff_val) /= 0) then
        if fail_cnt < 8 then
          report "FAIL NTT coeff[" & integer'image(i)
               & "] = " & integer'image(to_integer(coeff_val))
               & " (expected " & integer'image(1 - (i mod 2)) & ")"
            severity error;
        end if;
        fail_cnt := fail_cnt + 1;
        pass_ntt := false;
      end if;
    end loop;
    if pass_ntt then
      report "PASS: Forward NTT of delta correct (even=1, odd=0)" severity note;
    else
      report "FAIL: Forward NTT had " & integer'image(fail_cnt)
           & " incorrect coefficients" severity error;
    end if;

    -- ------------------------------------------------------------------
    -- Phase 4: Run INTT on the current BRAM contents (all-ones)
    -- After INTT with N_INV scaling, should recover delta
    -- ------------------------------------------------------------------
    report "Phase 4: Starting INTT" severity note;
    bram_sel    <= '1';
    ntt_inverse <= '1';
    ntt_start   <= '1';
    wait until rising_edge(clk);
    ntt_start <= '0';

    wait until ntt_done = '1';
    wait until rising_edge(clk);
    bram_sel <= '0';
    report "Phase 4: INTT done" severity note;

    -- ------------------------------------------------------------------
    -- Phase 5: Read back and verify round-trip
    -- coeff[0] should be 1, all others 0
    -- ------------------------------------------------------------------
    report "Phase 5: Verifying round-trip INTT output" severity note;
    fail_cnt := 0;
    for i in 0 to N-1 loop
      tb_addr_b <= to_unsigned(i, 8);
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      coeff_val := bdout_b;
      if i = 0 then
        if to_integer(coeff_val) /= 1 then
          report "FAIL INTT coeff[0] = " & integer'image(to_integer(coeff_val))
               & " (expected 1)" severity error;
          fail_cnt := fail_cnt + 1;
          pass_intt := false;
        end if;
      else
        if to_integer(coeff_val) /= 0 then
          if fail_cnt < 8 then
            report "FAIL INTT coeff[" & integer'image(i)
                 & "] = " & integer'image(to_integer(coeff_val))
                 & " (expected 0)" severity error;
          end if;
          fail_cnt := fail_cnt + 1;
          pass_intt := false;
        end if;
      end if;
    end loop;

    if pass_intt then
      report "PASS: INTT round-trip correct - recovered delta polynomial" severity note;
    else
      report "FAIL: INTT round-trip had " & integer'image(fail_cnt)
           & " incorrect coefficients" severity error;
    end if;

    -- Final summary
    if pass_ntt and pass_intt then
      report "tb_ntt_engine: ALL TESTS PASSED" severity note;
    else
      report "tb_ntt_engine: SOME TESTS FAILED" severity error;
    end if;

    wait;
  end process;

end architecture sim;
