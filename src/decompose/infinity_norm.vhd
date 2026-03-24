library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Poly-level infinity_norm: checks if all 256 coefficients satisfy |coeff|_centred < bound.
-- Coefficients are unsigned [0, q-1]; centred interpretation:
--   if coeff >= (q+1)/2 = 4190209: centred value = q - coeff (positive, mapped from negative)
--   else:                           centred value = coeff
-- Outputs pass='1' if all |coeff|_centred < bound, pass='0' on any violation.
-- Early termination: transitions to S_FAIL on first violation.

entity infinity_norm is
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;
    start    : in  std_logic;
    bound    : in  unsigned(22 downto 0);   -- bound B; check |coeff| < B
    src_addr : out unsigned(7 downto 0);
    src_data : in  unsigned(22 downto 0);
    pass     : out std_logic;               -- '1' iff all passed
    done     : out std_logic;
    busy     : out std_logic
  );
end entity infinity_norm;

architecture rtl of infinity_norm is

  -- (q+1)/2 = 4190209; above this, coefficient is "negative" in centred form
  constant HALF_Q_PLUS : unsigned(22 downto 0) :=
      to_unsigned((DIL_Q + 1) / 2, 23);   -- 4190209

  type t_state is (S_IDLE, S_READ, S_WAIT, S_CHECK, S_FAIL, S_DONE);
  signal state : t_state := S_IDLE;
  signal idx   : unsigned(7 downto 0) := (others => '0');

  -- Latch src_data after BRAM latency
  signal src_data_r : unsigned(22 downto 0) := (others => '0');
  signal addr_r     : unsigned(7 downto 0)  := (others => '0');
  -- Latch bound at start for timing stability
  signal bound_r    : unsigned(22 downto 0) := (others => '0');

begin

  process(clk)
    variable cent_v   : unsigned(22 downto 0);  -- centred absolute value
    variable coeff_v  : unsigned(22 downto 0);
    variable fail_v   : boolean;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state      <= S_IDLE;
        done       <= '0';
        busy       <= '0';
        pass       <= '0';
        idx        <= (others => '0');
        src_data_r <= (others => '0');
        bound_r    <= (others => '0');
      else
        done <= '0';

        case state is

          when S_IDLE =>
            pass <= '0';
            busy <= '0';
            if start = '1' then
              idx     <= (others => '0');
              bound_r <= bound;       -- latch bound
              busy    <= '1';
              state   <= S_READ;
            end if;

          when S_READ =>
            src_addr <= idx;
            addr_r   <= idx;
            state    <= S_WAIT;

          -- Wait 1 cycle for BRAM output
          when S_WAIT =>
            src_data_r <= src_data;
            state      <= S_CHECK;

          when S_CHECK =>
            coeff_v := src_data_r;

            -- Compute centred absolute value
            if coeff_v >= HALF_Q_PLUS then
              -- Negative centred: |val| = q - coeff
              cent_v := to_unsigned(DIL_Q, 23) - coeff_v;
            else
              cent_v := coeff_v;
            end if;

            -- Check |coeff| < bound (strictly less than)
            fail_v := (cent_v >= bound_r);

            if fail_v then
              state <= S_FAIL;
            elsif addr_r = to_unsigned(255, 8) then
              state <= S_DONE;
            else
              idx   <= addr_r + 1;
              state <= S_READ;
            end if;

          -- Violation found: output done with pass='0'
          when S_FAIL =>
            pass  <= '0';
            done  <= '1';
            busy  <= '0';
            state <= S_IDLE;

          -- All 256 passed
          when S_DONE =>
            pass  <= '1';
            done  <= '1';
            busy  <= '0';
            state <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
