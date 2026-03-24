library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- CRYSTALS-Dilithium top-level integration wrapper
-- Instantiates NTT engine, 4 poly BRAMs, arithmetic units and stubs for
-- keygen / sign / verify controllers.
-- mode: "00"=keygen, "01"=sign, "10"=verify
entity dilithium_top is
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;
    mode        : in  std_logic_vector(1 downto 0);
    start       : in  std_logic;
    seed        : in  std_logic_vector(63 downto 0);
    done        : out std_logic;
    busy        : out std_logic;
    verify_pass : out std_logic
  );
end entity dilithium_top;

architecture rtl of dilithium_top is

  -- -----------------------------------------------------------------------
  -- Type declarations
  -- -----------------------------------------------------------------------
  type t_coeff_arr is array(0 to 3) of unsigned(22 downto 0);
  type t_addr_arr  is array(0 to 3) of unsigned(7 downto 0);

  -- -----------------------------------------------------------------------
  -- Component declarations
  -- -----------------------------------------------------------------------

  component poly_bram is
    port (
      clk    : in  std_logic;
      we_a   : in  std_logic;
      addr_a : in  unsigned(7 downto 0);
      din_a  : in  unsigned(22 downto 0);
      dout_a : out unsigned(22 downto 0);
      we_b   : in  std_logic;
      addr_b : in  unsigned(7 downto 0);
      din_b  : in  unsigned(22 downto 0);
      dout_b : out unsigned(22 downto 0)
    );
  end component poly_bram;

  component ntt_engine is
    port (
      clk     : in  std_logic;
      rst     : in  std_logic;
      start   : in  std_logic;
      inverse : in  std_logic;
      we_a    : out std_logic;
      addr_a  : out unsigned(7 downto 0);
      din_a   : out unsigned(22 downto 0);
      dout_a  : in  unsigned(22 downto 0);
      we_b    : out std_logic;
      addr_b  : out unsigned(7 downto 0);
      din_b   : out unsigned(22 downto 0);
      dout_b  : in  unsigned(22 downto 0);
      done    : out std_logic;
      busy    : out std_logic
    );
  end component ntt_engine;

  component poly_add is
    port (
      clk    : in  std_logic;
      rst    : in  std_logic;
      start  : in  std_logic;
      we_a   : out std_logic;
      addr_a : out unsigned(7 downto 0);
      din_a  : out unsigned(22 downto 0);
      dout_a : in  unsigned(22 downto 0);
      we_b   : out std_logic;
      addr_b : out unsigned(7 downto 0);
      din_b  : out unsigned(22 downto 0);
      dout_b : in  unsigned(22 downto 0);
      we_c   : out std_logic;
      addr_c : out unsigned(7 downto 0);
      din_c  : out unsigned(22 downto 0);
      done   : out std_logic;
      busy   : out std_logic
    );
  end component poly_add;

  component poly_sub is
    port (
      clk    : in  std_logic;
      rst    : in  std_logic;
      start  : in  std_logic;
      we_a   : out std_logic;
      addr_a : out unsigned(7 downto 0);
      din_a  : out unsigned(22 downto 0);
      dout_a : in  unsigned(22 downto 0);
      we_b   : out std_logic;
      addr_b : out unsigned(7 downto 0);
      din_b  : out unsigned(22 downto 0);
      dout_b : in  unsigned(22 downto 0);
      we_c   : out std_logic;
      addr_c : out unsigned(7 downto 0);
      din_c  : out unsigned(22 downto 0);
      done   : out std_logic;
      busy   : out std_logic
    );
  end component poly_sub;

  component poly_basemul is
    port (
      clk    : in  std_logic;
      rst    : in  std_logic;
      start  : in  std_logic;
      we_a   : out std_logic;
      addr_a : out unsigned(7 downto 0);
      din_a  : out unsigned(22 downto 0);
      dout_a : in  unsigned(22 downto 0);
      we_b   : out std_logic;
      addr_b : out unsigned(7 downto 0);
      din_b  : out unsigned(22 downto 0);
      dout_b : in  unsigned(22 downto 0);
      we_c   : out std_logic;
      addr_c : out unsigned(7 downto 0);
      din_c  : out unsigned(22 downto 0);
      done   : out std_logic;
      busy   : out std_logic
    );
  end component poly_basemul;

  component lfsr_prng is
    port (
      clk    : in  std_logic;
      rst    : in  std_logic;
      seed   : in  std_logic_vector(63 downto 0);
      load   : in  std_logic;
      enable : in  std_logic;
      rnd    : out std_logic_vector(63 downto 0);
      valid  : out std_logic
    );
  end component lfsr_prng;

  component cbd_sampler is
    port (
      clk    : in  std_logic;
      rst    : in  std_logic;
      start  : in  std_logic;
      rnd_in : in  std_logic_vector(63 downto 0);
      rnd_v  : in  std_logic;
      we_out : out std_logic;
      addr   : out unsigned(7 downto 0);
      coeff  : out unsigned(22 downto 0);
      done   : out std_logic
    );
  end component cbd_sampler;

  -- -----------------------------------------------------------------------
  -- Top-level FSM
  -- -----------------------------------------------------------------------
  type t_top_state is (S_IDLE, S_RUNNING, S_DONE);
  signal top_state : t_top_state := S_IDLE;

  -- -----------------------------------------------------------------------
  -- BRAM bus signals (4 BRAMs, dual-port each)
  -- -----------------------------------------------------------------------
  signal bwe_a   : std_logic_vector(3 downto 0)  := (others => '0');
  signal baddr_a : t_addr_arr                    := (others => (others => '0'));
  signal bdin_a  : t_coeff_arr                   := (others => (others => '0'));
  signal bdout_a : t_coeff_arr                   := (others => (others => '0'));

  signal bwe_b   : std_logic_vector(3 downto 0)  := (others => '0');
  signal baddr_b : t_addr_arr                    := (others => (others => '0'));
  signal bdin_b  : t_coeff_arr                   := (others => (others => '0'));
  signal bdout_b : t_coeff_arr                   := (others => (others => '0'));

  -- -----------------------------------------------------------------------
  -- NTT engine signals
  -- -----------------------------------------------------------------------
  signal ntt_start   : std_logic := '0';
  signal ntt_inverse : std_logic := '0';
  signal ntt_we_a    : std_logic;
  signal ntt_addr_a  : unsigned(7 downto 0);
  signal ntt_din_a   : unsigned(22 downto 0);
  signal ntt_dout_a  : unsigned(22 downto 0) := (others => '0');
  signal ntt_we_b    : std_logic;
  signal ntt_addr_b  : unsigned(7 downto 0);
  signal ntt_din_b   : unsigned(22 downto 0);
  signal ntt_dout_b  : unsigned(22 downto 0) := (others => '0');
  signal ntt_done    : std_logic;
  signal ntt_busy    : std_logic;

  -- -----------------------------------------------------------------------
  -- poly_add / poly_sub / poly_basemul signals
  -- -----------------------------------------------------------------------
  signal add_start  : std_logic := '0';
  signal add_we_a   : std_logic; signal add_addr_a : unsigned(7 downto 0);
  signal add_din_a  : unsigned(22 downto 0); signal add_dout_a : unsigned(22 downto 0) := (others => '0');
  signal add_we_b   : std_logic; signal add_addr_b : unsigned(7 downto 0);
  signal add_din_b  : unsigned(22 downto 0); signal add_dout_b : unsigned(22 downto 0) := (others => '0');
  signal add_we_c   : std_logic; signal add_addr_c : unsigned(7 downto 0);
  signal add_din_c  : unsigned(22 downto 0);
  signal add_done   : std_logic; signal add_busy : std_logic;

  signal sub_start  : std_logic := '0';
  signal sub_we_a   : std_logic; signal sub_addr_a : unsigned(7 downto 0);
  signal sub_din_a  : unsigned(22 downto 0); signal sub_dout_a : unsigned(22 downto 0) := (others => '0');
  signal sub_we_b   : std_logic; signal sub_addr_b : unsigned(7 downto 0);
  signal sub_din_b  : unsigned(22 downto 0); signal sub_dout_b : unsigned(22 downto 0) := (others => '0');
  signal sub_we_c   : std_logic; signal sub_addr_c : unsigned(7 downto 0);
  signal sub_din_c  : unsigned(22 downto 0);
  signal sub_done   : std_logic; signal sub_busy : std_logic;

  signal bmul_start : std_logic := '0';
  signal bmul_we_a  : std_logic; signal bmul_addr_a : unsigned(7 downto 0);
  signal bmul_din_a : unsigned(22 downto 0); signal bmul_dout_a : unsigned(22 downto 0) := (others => '0');
  signal bmul_we_b  : std_logic; signal bmul_addr_b : unsigned(7 downto 0);
  signal bmul_din_b : unsigned(22 downto 0); signal bmul_dout_b : unsigned(22 downto 0) := (others => '0');
  signal bmul_we_c  : std_logic; signal bmul_addr_c : unsigned(7 downto 0);
  signal bmul_din_c : unsigned(22 downto 0);
  signal bmul_done  : std_logic; signal bmul_busy : std_logic;

  -- -----------------------------------------------------------------------
  -- PRNG / CBD sampler signals
  -- -----------------------------------------------------------------------
  signal prng_load   : std_logic := '0';
  signal prng_enable : std_logic := '0';
  signal prng_rnd    : std_logic_vector(63 downto 0);
  signal prng_valid  : std_logic;

  signal cbd_start  : std_logic := '0';
  signal cbd_we_out : std_logic;
  signal cbd_addr   : unsigned(7 downto 0);
  signal cbd_coeff  : unsigned(22 downto 0);
  signal cbd_done   : std_logic;

  -- -----------------------------------------------------------------------
  -- Controller done pulses (stubs — set to '0' until controllers written)
  -- -----------------------------------------------------------------------
  signal ctrl_done    : std_logic := '0';
  signal done_r       : std_logic := '0';
  signal busy_r       : std_logic := '0';
  signal verify_pass_r : std_logic := '0';

begin

  -- -----------------------------------------------------------------------
  -- 4 poly BRAMs: BRAM 0 = A port, BRAM 1 = B port,
  --               BRAM 2 = C/result,  BRAM 3 = scratch
  -- Port A is driven by the NTT engine (BRAM 0 only for NTT).
  -- All other ports are left at default (NOP) until controllers are added.
  -- -----------------------------------------------------------------------
  gen_brams: for i in 0 to 3 generate
    bram_i: poly_bram
      port map (
        clk    => clk,
        we_a   => bwe_a(i),
        addr_a => baddr_a(i),
        din_a  => bdin_a(i),
        dout_a => bdout_a(i),
        we_b   => bwe_b(i),
        addr_b => baddr_b(i),
        din_b  => bdin_b(i),
        dout_b => bdout_b(i)
      );
  end generate gen_brams;

  -- -----------------------------------------------------------------------
  -- NTT engine — connected to BRAM 0
  -- -----------------------------------------------------------------------
  u_ntt: ntt_engine
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

  -- Route NTT engine to BRAM 0
  bwe_a(0)   <= ntt_we_a;
  baddr_a(0) <= ntt_addr_a;
  bdin_a(0)  <= ntt_din_a;
  ntt_dout_a <= bdout_a(0);
  bwe_b(0)   <= ntt_we_b;
  baddr_b(0) <= ntt_addr_b;
  bdin_b(0)  <= ntt_din_b;
  ntt_dout_b <= bdout_b(0);

  -- -----------------------------------------------------------------------
  -- poly_add — connected to BRAMs 0, 1, 2
  -- -----------------------------------------------------------------------
  u_add: poly_add
    port map (
      clk    => clk, rst => rst, start => add_start,
      we_a   => add_we_a,   addr_a => add_addr_a,
      din_a  => add_din_a,  dout_a => add_dout_a,
      we_b   => add_we_b,   addr_b => add_addr_b,
      din_b  => add_din_b,  dout_b => add_dout_b,
      we_c   => add_we_c,   addr_c => add_addr_c,
      din_c  => add_din_c,
      done   => add_done,   busy => add_busy
    );

  -- poly_sub
  u_sub: poly_sub
    port map (
      clk    => clk, rst => rst, start => sub_start,
      we_a   => sub_we_a,   addr_a => sub_addr_a,
      din_a  => sub_din_a,  dout_a => sub_dout_a,
      we_b   => sub_we_b,   addr_b => sub_addr_b,
      din_b  => sub_din_b,  dout_b => sub_dout_b,
      we_c   => sub_we_c,   addr_c => sub_addr_c,
      din_c  => sub_din_c,
      done   => sub_done,   busy => sub_busy
    );

  -- poly_basemul
  u_bmul: poly_basemul
    port map (
      clk    => clk, rst => rst, start => bmul_start,
      we_a   => bmul_we_a,   addr_a => bmul_addr_a,
      din_a  => bmul_din_a,  dout_a => bmul_dout_a,
      we_b   => bmul_we_b,   addr_b => bmul_addr_b,
      din_b  => bmul_din_b,  dout_b => bmul_dout_b,
      we_c   => bmul_we_c,   addr_c => bmul_addr_c,
      din_c  => bmul_din_c,
      done   => bmul_done,   busy => bmul_busy
    );

  -- -----------------------------------------------------------------------
  -- PRNG + CBD sampler
  -- -----------------------------------------------------------------------
  u_prng: lfsr_prng
    port map (
      clk    => clk,
      rst    => rst,
      seed   => seed,
      load   => prng_load,
      enable => prng_enable,
      rnd    => prng_rnd,
      valid  => prng_valid
    );

  u_cbd: cbd_sampler
    port map (
      clk    => clk,
      rst    => rst,
      start  => cbd_start,
      rnd_in => prng_rnd,
      rnd_v  => prng_valid,
      we_out => cbd_we_out,
      addr   => cbd_addr,
      coeff  => cbd_coeff,
      done   => cbd_done
    );

  -- CBD sampler output written to BRAM 3 (scratch)
  bwe_a(3)   <= cbd_we_out;
  baddr_a(3) <= cbd_addr;
  bdin_a(3)  <= cbd_coeff;

  -- -----------------------------------------------------------------------
  -- Top-level FSM
  -- -----------------------------------------------------------------------
  p_fsm: process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        top_state    <= S_IDLE;
        done_r       <= '0';
        busy_r       <= '0';
        verify_pass_r <= '0';
        ntt_start    <= '0';
        add_start    <= '0';
        sub_start    <= '0';
        bmul_start   <= '0';
        prng_load    <= '0';
        prng_enable  <= '0';
        cbd_start    <= '0';
      else
        done_r    <= '0';   -- single-cycle pulse default

        case top_state is

          when S_IDLE =>
            if start = '1' then
              busy_r    <= '1';
              -- Load PRNG seed on every start
              prng_load <= '1';
              top_state <= S_RUNNING;
            end if;

          when S_RUNNING =>
            prng_load <= '0';
            -- Stub: controllers would drive ntt_start, add_start, etc.
            -- For now, wait for ctrl_done (tied to '0' until real controllers
            -- are instantiated). In simulation, this will stall in S_RUNNING
            -- until controllers drive ctrl_done = '1'.
            if ctrl_done = '1' then
              busy_r    <= '0';
              done_r    <= '1';
              top_state <= S_DONE;
              -- Capture verify result only when in verify mode
              if mode = "10" then
                verify_pass_r <= '1';  -- placeholder: real logic from verify ctrl
              end if;
            end if;

          when S_DONE =>
            top_state <= S_IDLE;

        end case;
      end if;
    end if;
  end process p_fsm;

  done        <= done_r;
  busy        <= busy_r;
  verify_pass <= verify_pass_r;

end architecture rtl;
