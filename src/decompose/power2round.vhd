library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Poly-level power2round: splits each coefficient a in [0, q-1] into (a1, a0)
-- using D=13:
--   a1 = floor((a + 2^(D-1) - 1) / 2^D) = floor((a + 4095) / 8192)
--   a0 = a - a1 * 8192     (centred: a0 in (-4096, 4096])
--
-- a1 range: [0, 1023] (fits in 10 bits), stored as unsigned(22 downto 0).
-- a0 stored as unsigned mod-q (negative values: q + a0).
-- Outputs two destination BRAMs: one for a1, one for a0.
-- States: S_IDLE -> S_READ -> S_WAIT -> S_COMPUTE -> S_WRITE -> next or S_DONE

entity power2round is
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;
    start    : in  std_logic;
    src_addr : out unsigned(7 downto 0);
    src_data : in  unsigned(22 downto 0);
    a1_we    : out std_logic;
    a1_addr  : out unsigned(7 downto 0);
    a1_data  : out unsigned(22 downto 0);
    a0_we    : out std_logic;
    a0_addr  : out unsigned(7 downto 0);
    a0_data  : out unsigned(22 downto 0);
    done     : out std_logic;
    busy     : out std_logic
  );
end entity power2round;

architecture rtl of power2round is

  -- D=13: 2^(D-1) = 4096, so bias = 4095 = 2^(D-1) - 1
  constant P2R_BIAS : integer := 4095;   -- (1 << (D-1)) - 1
  constant P2R_DIV  : integer := 8192;   -- 1 << D

  type t_state is (S_IDLE, S_READ, S_WAIT, S_COMPUTE, S_WRITE, S_DONE);
  signal state : t_state := S_IDLE;
  signal idx   : unsigned(7 downto 0) := (others => '0');

  -- Registered compute results
  signal a1_reg      : unsigned(22 downto 0) := (others => '0');
  signal a0_reg      : unsigned(22 downto 0) := (others => '0');
  signal addr_reg    : unsigned(7 downto 0)  := (others => '0');
  -- Latch src_data in WAIT state to hold for COMPUTE
  signal src_data_r  : unsigned(22 downto 0) := (others => '0');

begin

  process(clk)
    variable a_v   : integer;
    variable a1_v  : integer;
    variable a0_v  : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state      <= S_IDLE;
        done       <= '0';
        busy       <= '0';
        a1_we      <= '0';
        a0_we      <= '0';
        idx        <= (others => '0');
        src_data_r <= (others => '0');
      else
        done  <= '0';
        a1_we <= '0';
        a0_we <= '0';

        case state is

          when S_IDLE =>
            busy <= '0';
            if start = '1' then
              idx   <= (others => '0');
              busy  <= '1';
              state <= S_READ;
            end if;

          when S_READ =>
            src_addr <= idx;
            state    <= S_WAIT;

          -- Latch BRAM output (1-cycle latency)
          when S_WAIT =>
            src_data_r <= src_data;
            addr_reg   <= idx;
            state      <= S_COMPUTE;

          -- Registered compute: integer arithmetic
          when S_COMPUTE =>
            a_v   := to_integer(src_data_r);          -- [0, 8380416]
            a1_v  := (a_v + P2R_BIAS) / P2R_DIV;      -- floor((a+4095)/8192)
            a0_v  := a_v - a1_v * P2R_DIV;            -- a - a1*8192

            a1_reg <= to_unsigned(a1_v, 23);

            if a0_v < 0 then
              a0_reg <= to_unsigned(DIL_Q + a0_v, 23);
            else
              a0_reg <= to_unsigned(a0_v, 23);
            end if;

            state <= S_WRITE;

          when S_WRITE =>
            a1_data <= a1_reg;
            a1_addr <= addr_reg;
            a1_we   <= '1';
            a0_data <= a0_reg;
            a0_addr <= addr_reg;
            a0_we   <= '1';

            if addr_reg = to_unsigned(255, 8) then
              state <= S_DONE;
            else
              idx   <= addr_reg + 1;
              state <= S_READ;
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
