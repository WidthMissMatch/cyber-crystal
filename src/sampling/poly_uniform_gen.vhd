library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Generates one polynomial with uniform random coefficients in [0, q-1]
-- using 3-byte rejection sampling, into a destination BRAM.
-- Instantiates lfsr_prng and uniform_sampler internally.
-- The LFSR runs continuously; uniform_sampler requests bytes via rnd_req.
-- When uniform_sampler asserts valid, the accepted coefficient is written to BRAM.
-- 256 accepted coefficients are written before done is asserted.
entity poly_uniform_gen is
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
end entity poly_uniform_gen;

architecture rtl of poly_uniform_gen is

  -- LFSR interface
  signal lfsr_load    : std_logic := '0';
  signal lfsr_enable  : std_logic := '0';
  signal lfsr_rnd_out : std_logic_vector(7 downto 0);
  signal lfsr_valid   : std_logic;

  -- uniform_sampler interface
  signal us_start     : std_logic := '0';
  signal us_rnd_byte  : std_logic_vector(7 downto 0);
  signal us_rnd_req   : std_logic;
  signal us_candidate : unsigned(22 downto 0);
  signal us_valid     : std_logic;
  signal us_done      : std_logic;

  -- FSM
  type t_state is (S_IDLE, S_SEED, S_RUNNING, S_DONE);
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

  -- Feed LFSR output directly to uniform_sampler byte input
  -- The uniform_sampler sees bytes that were produced one cycle ago (registered LFSR output).
  -- rnd_req from uniform_sampler gates lfsr_enable, so we advance LFSR only when sampler needs a byte.
  us_rnd_byte <= lfsr_rnd_out;
  lfsr_enable <= us_rnd_req;

  -- Instantiate uniform_sampler
  u_us : entity work.uniform_sampler
    port map (
      clk       => clk,
      rst       => rst,
      start     => us_start,
      rnd_byte  => us_rnd_byte,
      rnd_req   => us_rnd_req,
      candidate => us_candidate,
      valid     => us_valid,
      done      => us_done
    );

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state    <= S_IDLE;
        lfsr_load <= '0';
        we_a     <= '0';
        addr_a   <= (others => '0');
        din_a    <= (others => '0');
        done     <= '0';
        busy     <= '0';
        addr_r   <= (others => '0');
        us_start <= '0';
      else
        -- Default deasserts
        lfsr_load <= '0';
        we_a      <= '0';
        done      <= '0';
        us_start  <= '0';

        case state is

          when S_IDLE =>
            busy <= '0';
            if start = '1' then
              addr_r <= (others => '0');
              busy   <= '1';
              state  <= S_SEED;
            end if;

          -- Load seed into LFSR for one cycle, then kick the sampler
          when S_SEED =>
            lfsr_load <= '1';
            us_start  <= '1';    -- start the uniform_sampler on the same cycle
            state     <= S_RUNNING;

          -- Keep running: uniform_sampler requests bytes (gates lfsr_enable),
          -- when it produces a valid coefficient, write to BRAM and count.
          when S_RUNNING =>
            if us_valid = '1' then
              din_a  <= us_candidate;
              addr_a <= addr_r;
              we_a   <= '1';

              if addr_r = to_unsigned(DIL_N - 1, 8) then
                state <= S_DONE;
              else
                addr_r   <= addr_r + 1;
                -- Restart the sampler for the next coefficient
                us_start <= '1';
              end if;
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
