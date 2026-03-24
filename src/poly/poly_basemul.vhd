library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- Pointwise multiplication of two NTT-domain polynomials mod q = 8380417
-- 128 pairs of degree-1 polynomial basemul operations
-- basemul((a0,a1), (b0,b1), zeta) = (a0*b0 + a1*b1*zeta, a0*b1 + a1*b0)
entity poly_basemul is
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    start      : in  std_logic;
    src_a_addr : out unsigned(7 downto 0);
    src_a_data : in  unsigned(22 downto 0);
    src_b_addr : out unsigned(7 downto 0);
    src_b_data : in  unsigned(22 downto 0);
    dst_we     : out std_logic;
    dst_addr   : out unsigned(7 downto 0);
    dst_data   : out unsigned(22 downto 0);
    done       : out std_logic;
    busy       : out std_logic
  );
end entity poly_basemul;

architecture rtl of poly_basemul is

  type t_state is (
    S_IDLE,
    S_READ_A0B0, S_WAIT_A0B0, S_LATCH_A0B0,
    S_WAIT_A1B1, S_LATCH_A1B1,
    S_MUL_1, S_MUL_2, S_MUL_3,
    S_WRITE_R0, S_NEXT, S_DONE
  );

  signal state    : t_state              := S_IDLE;
  signal pair_idx : unsigned(6 downto 0) := (others => '0');

  signal a0, a1, b0, b1 : unsigned(22 downto 0) := (others => '0');

  signal p_a0b0, p_a1b1, p_a0b1, p_a1b0 : unsigned(45 downto 0) := (others => '0');
  signal m_a0b0, m_a1b1, m_a0b1, m_a1b0 : unsigned(22 downto 0) := (others => '0');
  signal m_a1b1z : unsigned(22 downto 0) := (others => '0');

  signal cur_zeta : unsigned(22 downto 0) := (others => '0');
  signal r1_reg   : unsigned(22 downto 0) := (others => '0');

  function barrett(x : unsigned(45 downto 0)) return unsigned is
    variable x_ext  : unsigned(69 downto 0);
    variable quot   : unsigned(23 downto 0);
    variable prod_q : unsigned(46 downto 0);
    variable diff   : unsigned(46 downto 0);
    variable r      : unsigned(22 downto 0);
  begin
    x_ext  := x * BARRETT_M;
    quot   := x_ext(69 downto 46);
    prod_q := quot * to_unsigned(DIL_Q, 23);
    diff   := resize(x, 47) - prod_q;
    if diff >= DIL_Q then
      r := resize(diff - DIL_Q, 23);
    else
      r := resize(diff, 23);
    end if;
    return r;
  end function;

begin

  process(clk)
    variable sum       : unsigned(23 downto 0);
    variable zeta_prod : unsigned(45 downto 0);
    variable r0, r1    : unsigned(22 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state    <= S_IDLE;
        done     <= '0';
        busy     <= '0';
        dst_we   <= '0';
        pair_idx <= (others => '0');
      else
        dst_we <= '0';

        case state is

          when S_IDLE =>
            done <= '0';
            busy <= '0';
            if start = '1' then
              pair_idx <= (others => '0');
              busy     <= '1';
              state    <= S_READ_A0B0;
            end if;

          when S_READ_A0B0 =>
            src_a_addr <= pair_idx & '0';
            src_b_addr <= pair_idx & '0';
            state      <= S_WAIT_A0B0;

          when S_WAIT_A0B0 =>
            state <= S_LATCH_A0B0;

          when S_LATCH_A0B0 =>
            a0 <= src_a_data;
            b0 <= src_b_data;
            src_a_addr <= pair_idx & '1';
            src_b_addr <= pair_idx & '1';
            state      <= S_WAIT_A1B1;

          when S_WAIT_A1B1 =>
            state <= S_LATCH_A1B1;

          when S_LATCH_A1B1 =>
            a1 <= src_a_data;
            b1 <= src_b_data;
            if pair_idx(0) = '0' then
              cur_zeta <= C_ZETAS(64 + to_integer(pair_idx(6 downto 1)));
            else
              cur_zeta <= to_unsigned(DIL_Q, 23) -
                          C_ZETAS(64 + to_integer(pair_idx(6 downto 1)));
            end if;
            state <= S_MUL_1;

          when S_MUL_1 =>
            p_a0b0 <= a0 * b0;
            p_a1b1 <= a1 * b1;
            p_a0b1 <= a0 * b1;
            p_a1b0 <= a1 * b0;
            state  <= S_MUL_2;

          when S_MUL_2 =>
            m_a0b0 <= barrett(p_a0b0);
            m_a1b1 <= barrett(p_a1b1);
            m_a0b1 <= barrett(p_a0b1);
            m_a1b0 <= barrett(p_a1b0);
            -- Compute a1*b1*zeta
            zeta_prod := barrett(p_a1b1) * cur_zeta;
            m_a1b1z   <= barrett(zeta_prod);
            -- r1 = (a0*b1 + a1*b0) mod q
            sum := resize(barrett(p_a0b1), 24) + resize(barrett(p_a1b0), 24);
            if sum >= DIL_Q then
              r1 := resize(sum - DIL_Q, 23);
            else
              r1 := resize(sum, 23);
            end if;
            r1_reg <= r1;
            state  <= S_MUL_3;

          when S_MUL_3 =>
            -- r0 = (m_a0b0 + m_a1b1z) mod q
            sum := resize(m_a0b0, 24) + resize(m_a1b1z, 24);
            if sum >= DIL_Q then
              r0 := resize(sum - DIL_Q, 23);
            else
              r0 := resize(sum, 23);
            end if;
            dst_data <= r0;
            dst_addr <= pair_idx & '0';
            dst_we   <= '1';
            state    <= S_WRITE_R0;

          when S_WRITE_R0 =>
            dst_data <= r1_reg;
            dst_addr <= pair_idx & '1';
            dst_we   <= '1';
            state    <= S_NEXT;

          when S_NEXT =>
            if pair_idx = 127 then
              state <= S_DONE;
            else
              pair_idx <= pair_idx + 1;
              state    <= S_READ_A0B0;
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
