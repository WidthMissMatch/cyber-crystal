library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- 3-byte rejection sampler for uniform distribution in [0, q-1]
-- Assembles 3 bytes into a 23-bit candidate = {byte2[6:0], byte1[7:0], byte0[7:0]}
-- Rejects if candidate >= DIL_Q and retries.
-- Outputs one accepted coefficient per valid pulse.
entity uniform_sampler is
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    start     : in  std_logic;
    rnd_byte  : in  std_logic_vector(7 downto 0);  -- next random byte from LFSR
    rnd_req   : out std_logic;                      -- request next byte from LFSR
    candidate : out unsigned(22 downto 0);
    valid     : out std_logic;
    done      : out std_logic
  );
end entity uniform_sampler;

architecture rtl of uniform_sampler is

  type t_state is (S_IDLE, S_BYTE0, S_BYTE1, S_BYTE2, S_CHECK, S_OUTPUT, S_DONE);
  signal state    : t_state := S_IDLE;

  signal byte0_r  : std_logic_vector(7 downto 0) := (others => '0');
  signal byte1_r  : std_logic_vector(7 downto 0) := (others => '0');
  signal byte2_r  : std_logic_vector(7 downto 0) := (others => '0');
  signal cand_reg : unsigned(22 downto 0)         := (others => '0');

begin

  process(clk)
    variable v_cand : unsigned(22 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state    <= S_IDLE;
        rnd_req  <= '0';
        valid    <= '0';
        done     <= '0';
        byte0_r  <= (others => '0');
        byte1_r  <= (others => '0');
        byte2_r  <= (others => '0');
        cand_reg <= (others => '0');
        candidate <= (others => '0');
      else
        -- Default deasserts
        rnd_req <= '0';
        valid   <= '0';
        done    <= '0';

        case state is

          when S_IDLE =>
            if start = '1' then
              state <= S_BYTE0;
            end if;

          -- Request and latch byte 0
          when S_BYTE0 =>
            rnd_req <= '1';
            byte0_r <= rnd_byte;
            state   <= S_BYTE1;

          -- Request and latch byte 1
          when S_BYTE1 =>
            rnd_req <= '1';
            byte1_r <= rnd_byte;
            state   <= S_BYTE2;

          -- Request and latch byte 2
          when S_BYTE2 =>
            rnd_req <= '1';
            byte2_r <= rnd_byte;
            state   <= S_CHECK;

          -- Assemble candidate and check against q
          when S_CHECK =>
            -- candidate[22:0] = {byte2[6:0], byte1[7:0], byte0[7:0]}
            v_cand := unsigned(byte2_r(6 downto 0)) & unsigned(byte1_r) & unsigned(byte0_r);
            v_cand := v_cand and to_unsigned(16#7FFFFF#, 23);
            if v_cand < to_unsigned(DIL_Q, 23) then
              cand_reg <= v_cand;
              state    <= S_OUTPUT;
            else
              -- Rejection: try again with 3 fresh bytes
              state <= S_BYTE0;
            end if;

          -- Output the accepted candidate for one cycle
          when S_OUTPUT =>
            candidate <= cand_reg;
            valid     <= '1';
            state     <= S_DONE;

          when S_DONE =>
            done  <= '1';
            state <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
