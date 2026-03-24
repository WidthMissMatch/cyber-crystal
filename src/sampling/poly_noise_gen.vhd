library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Generates one polynomial with CBD noise (eta=2) into a destination BRAM.
-- Instantiates lfsr_prng and cbd_sampler internally.
-- Each LFSR byte feeds the lower 4 bits to cbd_sampler (one coeff per byte).
-- Pipeline: enable LFSR -> 1 cycle -> lfsr valid -> cbd gets rnd_bits -> 1 cycle -> coeff_v.
-- Total 2 cycles per coefficient, 256 coefficients => at least 512 cycles in S_RUN/WAIT/WRITE.
entity poly_noise_gen is
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;
    start : in  std_logic;
    seed  : in  std_logic_vector(63 downto 0);
    we_a  : out std_logic;
    addr_a: out unsigned(7 downto 0);
    din_a : out unsigned(22 downto 0);
    done  : out std_logic;
    busy  : out std_logic
  );
end entity poly_noise_gen;

architecture rtl of poly_noise_gen is

  -- Internal LFSR control
  signal lfsr_load    : std_logic := '0';
  signal lfsr_enable  : std_logic := '0';
  signal lfsr_rnd_out : std_logic_vector(7 downto 0);
  signal lfsr_valid   : std_logic;

  -- CBD sampler connections
  signal cbd_rnd_bits : std_logic_vector(3 downto 0);
  signal cbd_rnd_valid: std_logic;
  signal cbd_coeff    : unsigned(22 downto 0);
  signal cbd_coeff_v  : std_logic;

  -- FSM
  type t_state is (S_IDLE, S_SEED, S_RUN_LFSR, S_WAIT1, S_WAIT2, S_WRITE, S_DONE);
  signal state  : t_state := S_IDLE;
  signal addr_r : unsigned(7 downto 0) := (others => '0');

begin

  -- Instantiate LFSR PRNG
  u_lfsr : entity work.lfsr_prng
    port map (
      clk     => clk,
      rst     => rst,
      seed    => seed,
      load    => lfsr_load,
      enable  => lfsr_enable,
      rnd_out => lfsr_rnd_out,
      valid   => lfsr_valid
    );

  -- Wire lower 4 bits of LFSR output to CBD sampler
  cbd_rnd_bits  <= lfsr_rnd_out(3 downto 0);
  cbd_rnd_valid <= lfsr_valid;

  -- Instantiate CBD sampler
  u_cbd : entity work.cbd_sampler
    generic map (G_ETA => DIL_ETA)
    port map (
      clk       => clk,
      rst       => rst,
      rnd_bits  => cbd_rnd_bits,
      rnd_valid => cbd_rnd_valid,
      coeff     => cbd_coeff,
      coeff_v   => cbd_coeff_v
    );

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state       <= S_IDLE;
        lfsr_load   <= '0';
        lfsr_enable <= '0';
        we_a        <= '0';
        addr_a      <= (others => '0');
        din_a       <= (others => '0');
        done        <= '0';
        busy        <= '0';
        addr_r      <= (others => '0');
      else
        -- Default deasserts
        lfsr_load   <= '0';
        lfsr_enable <= '0';
        we_a        <= '0';
        done        <= '0';

        case state is

          when S_IDLE =>
            busy  <= '0';
            if start = '1' then
              addr_r <= (others => '0');
              busy   <= '1';
              state  <= S_SEED;
            end if;

          -- Load seed into LFSR for one cycle
          when S_SEED =>
            lfsr_load <= '1';
            state     <= S_RUN_LFSR;

          -- Enable LFSR for one cycle; LFSR output appears next cycle with valid='1'
          when S_RUN_LFSR =>
            lfsr_enable <= '1';
            state       <= S_WAIT1;

          -- Wait one cycle: LFSR valid fires, CBD receives rnd_bits this cycle
          when S_WAIT1 =>
            state <= S_WAIT2;

          -- Wait one more cycle: cbd_coeff_v fires (registered output of cbd_sampler)
          when S_WAIT2 =>
            if cbd_coeff_v = '1' then
              din_a  <= cbd_coeff;
              addr_a <= addr_r;
              we_a   <= '1';
              state  <= S_WRITE;
            else
              -- Should not happen in normal operation, but guard against pipeline slip
              state <= S_WAIT2;
            end if;

          -- Write is already issued; advance address and decide next action
          when S_WRITE =>
            we_a <= '0';
            if addr_r = to_unsigned(DIL_N - 1, 8) then
              state <= S_DONE;
            else
              addr_r <= addr_r + 1;
              state  <= S_RUN_LFSR;
            end if;

          when S_DONE =>
            done  <= '1';
            busy  <= '0';
            state <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
