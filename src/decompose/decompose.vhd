library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Single-coefficient decompose: splits a in [0, q-1] into (a1, a0)
-- such that a = a1 * 2*GAMMA2 + a0, a1 in [0,43], a0 centred in (-GAMMA2, GAMMA2].
-- 1-cycle registered pipeline: valid_in -> compute -> register -> valid_out

entity decompose is
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    a_in      : in  unsigned(22 downto 0);       -- input coefficient [0, q-1]
    valid_in  : in  std_logic;
    a1_out    : out unsigned(5 downto 0);         -- high part [0, 43]
    a0_out    : out signed(18 downto 0);          -- low part centred
    valid_out : out std_logic
  );
end entity decompose;

architecture rtl of decompose is

  -- Constants for decompose algorithm (GAMMA2 = (Q-1)/88 branch)
  constant HALF_Q    : integer := (DIL_Q - 1) / 2;   -- 4190208
  constant TWO_G2    : integer := DIL_ALPHA;           -- 190464

  -- Pipeline stage registers
  signal valid_r  : std_logic := '0';
  signal a1_r     : unsigned(5 downto 0) := (others => '0');
  signal a0_r     : signed(18 downto 0) := (others => '0');

begin

  process(clk)
    variable a_v    : integer;
    variable t1_v   : integer;
    variable a1_v   : integer;
    variable a0_v   : integer;
    variable xor_v  : integer;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        valid_r <= '0';
        a1_r    <= (others => '0');
        a0_r    <= (others => '0');
      else
        valid_r <= valid_in;

        if valid_in = '1' then
          -- a_v is in [0, q-1]; treat as non-negative
          a_v := to_integer(a_in);

          -- Step 1: approximate a1 = floor((a + 127) / 128) * 11275 / 2^24
          -- Note: arithmetic right shift on signed in C; a_v >= 0 so safe
          t1_v := (a_v + 127) / 128;                   -- >> 7 (a_v >= 0)
          t1_v := (t1_v * 11275 + 8388608) / 16777216; -- * 11275 + 2^23, >> 24

          -- XOR trick: if t1_v > 43, (43 - t1_v) is negative -> arithmetic >>31 = all-1s
          -- then t1_v XOR (all-1s AND t1_v) = t1_v XOR t1_v = 0 -> clamp to 0
          -- if t1_v <= 43, (43 - t1_v) >= 0 -> >>31 = 0 -> t1_v XOR 0 = t1_v
          if (43 - t1_v) < 0 then
            xor_v := 0;                                  -- t1_v > 43: clamp to 0
          else
            xor_v := t1_v;
          end if;
          a1_v := xor_v;

          -- Step 2: a0 = a - a1 * 2*GAMMA2
          a0_v := a_v - a1_v * TWO_G2;

          -- Adjustment: if a0 > (q-1)/2, subtract q
          if a0_v > HALF_Q then
            a0_v := a0_v - DIL_Q;
          end if;

          a1_r <= to_unsigned(a1_v, 6);
          a0_r <= to_signed(a0_v, 19);
        end if;
      end if;
    end if;
  end process;

  a1_out    <= a1_r;
  a0_out    <= a0_r;
  valid_out <= valid_r;

end architecture rtl;
