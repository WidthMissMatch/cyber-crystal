library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.dilithium_pkg.all;

-- NTT/INTT engine for CRYSTALS-Dilithium (q=8380417, N=256)
-- Forward NTT: 7 layers of Cooley-Tukey butterflies
-- Inverse NTT: 7 layers of Gentleman-Sande butterflies + multiply by N_INV
-- Single butterfly unit, sequential in-place operation
entity ntt_engine is
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
end entity ntt_engine;

architecture rtl of ntt_engine is

  type t_state is (
    S_IDLE, S_SETUP_LAYER, S_READ, S_WAIT_RD, S_COMPUTE,
    S_WAIT_BF1, S_WRITE, S_NEXT_PAIR, S_NEXT_BLOCK, S_NEXT_LAYER,
    S_SCALE_INIT, S_SCALE_RD, S_SCALE_WAIT, S_SCALE_MUL, S_SCALE_WR,
    S_DONE
  );
  signal state : t_state := S_IDLE;

  signal layer     : unsigned(2 downto 0) := (others => '0');
  signal zeta_k    : unsigned(6 downto 0) := (others => '0');
  signal half_len  : unsigned(7 downto 0) := (others => '0');
  signal n_blocks  : unsigned(7 downto 0) := (others => '0');
  signal block_idx : unsigned(7 downto 0) := (others => '0');
  signal pair_idx  : unsigned(7 downto 0) := (others => '0');
  signal lo_addr   : unsigned(7 downto 0) := (others => '0');
  signal hi_addr   : unsigned(7 downto 0) := (others => '0');
  signal cur_zeta  : unsigned(22 downto 0) := (others => '0');
  signal val_lo    : unsigned(22 downto 0) := (others => '0');
  signal val_hi    : unsigned(22 downto 0) := (others => '0');
  signal bf_a_result : unsigned(22 downto 0) := (others => '0');
  signal bf_b_result : unsigned(22 downto 0) := (others => '0');
  signal scale_idx   : unsigned(7 downto 0) := (others => '0');
  signal scale_prod  : unsigned(45 downto 0) := (others => '0');

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

  function mod_add(a, b : unsigned(22 downto 0)) return unsigned is
    variable s : unsigned(23 downto 0);
  begin
    s := resize(a, 24) + resize(b, 24);
    if s >= DIL_Q then return resize(s - DIL_Q, 23);
    else return resize(s, 23); end if;
  end function;

  function mod_sub(a, b : unsigned(22 downto 0)) return unsigned is
  begin
    if a >= b then return resize(a - b, 23);
    else return resize((resize(a, 24) + to_unsigned(DIL_Q, 24)) - resize(b, 24), 23);
    end if;
  end function;

begin

  process(clk)
    variable t_val     : unsigned(22 downto 0);
    variable product   : unsigned(45 downto 0);
    variable base_addr : unsigned(8 downto 0);
    variable blk_size  : unsigned(8 downto 0);
    variable mult_tmp  : unsigned(17 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= S_IDLE; done <= '0'; busy <= '0';
        we_a <= '0'; we_b <= '0';
      else
        we_a <= '0'; we_b <= '0';

        case state is

          when S_IDLE =>
            done <= '0'; busy <= '0';
            if start = '1' then
              layer <= (others => '0');
              if inverse = '0' then zeta_k <= to_unsigned(1, 7);
              else zeta_k <= to_unsigned(127, 7); end if;
              busy <= '1'; state <= S_SETUP_LAYER;
            end if;

          when S_SETUP_LAYER =>
            if inverse = '0' then
              case to_integer(layer) is
                when 0 => half_len <= to_unsigned(128,8); n_blocks <= to_unsigned(1,8);
                when 1 => half_len <= to_unsigned(64,8);  n_blocks <= to_unsigned(2,8);
                when 2 => half_len <= to_unsigned(32,8);  n_blocks <= to_unsigned(4,8);
                when 3 => half_len <= to_unsigned(16,8);  n_blocks <= to_unsigned(8,8);
                when 4 => half_len <= to_unsigned(8,8);   n_blocks <= to_unsigned(16,8);
                when 5 => half_len <= to_unsigned(4,8);   n_blocks <= to_unsigned(32,8);
                when 6 => half_len <= to_unsigned(2,8);   n_blocks <= to_unsigned(64,8);
                when others => half_len <= to_unsigned(1,8); n_blocks <= to_unsigned(128,8);
              end case;
            else
              case to_integer(layer) is
                when 0 => half_len <= to_unsigned(2,8);   n_blocks <= to_unsigned(64,8);
                when 1 => half_len <= to_unsigned(4,8);   n_blocks <= to_unsigned(32,8);
                when 2 => half_len <= to_unsigned(8,8);   n_blocks <= to_unsigned(16,8);
                when 3 => half_len <= to_unsigned(16,8);  n_blocks <= to_unsigned(8,8);
                when 4 => half_len <= to_unsigned(32,8);  n_blocks <= to_unsigned(4,8);
                when 5 => half_len <= to_unsigned(64,8);  n_blocks <= to_unsigned(2,8);
                when 6 => half_len <= to_unsigned(128,8); n_blocks <= to_unsigned(1,8);
                when others => half_len <= to_unsigned(128,8); n_blocks <= to_unsigned(1,8);
              end case;
            end if;
            block_idx <= (others => '0'); pair_idx <= (others => '0');
            state <= S_READ;

          when S_READ =>
            blk_size  := shift_left(resize(half_len, 9), 1);
            mult_tmp  := resize(block_idx, 9) * blk_size;
            base_addr := mult_tmp(8 downto 0);
            lo_addr   <= resize(base_addr + resize(pair_idx, 9), 8);
            hi_addr   <= resize(base_addr + resize(pair_idx, 9) + resize(half_len, 9), 8);
            cur_zeta  <= C_ZETAS(to_integer(zeta_k));
            addr_a    <= resize(base_addr + resize(pair_idx, 9), 8);
            addr_b    <= resize(base_addr + resize(pair_idx, 9) + resize(half_len, 9), 8);
            state     <= S_WAIT_RD;

          when S_WAIT_RD =>
            state <= S_COMPUTE;

          when S_COMPUTE =>
            val_lo <= dout_a; val_hi <= dout_b;
            if inverse = '0' then
              product := cur_zeta * dout_b;
            else
              product := cur_zeta * mod_sub(dout_b, dout_a);
            end if;
            scale_prod <= product;
            state <= S_WAIT_BF1;

          when S_WAIT_BF1 =>
            t_val := barrett(scale_prod);
            if inverse = '0' then
              bf_a_result <= mod_add(val_lo, t_val);
              bf_b_result <= mod_sub(val_lo, t_val);
            else
              bf_a_result <= mod_add(val_lo, val_hi);
              bf_b_result <= t_val;
            end if;
            state <= S_WRITE;

          when S_WRITE =>
            we_a <= '1'; we_b <= '1';
            addr_a <= lo_addr; addr_b <= hi_addr;
            din_a <= bf_a_result; din_b <= bf_b_result;
            state <= S_NEXT_PAIR;

          when S_NEXT_PAIR =>
            if pair_idx + 1 >= half_len then
              pair_idx <= (others => '0'); state <= S_NEXT_BLOCK;
            else
              pair_idx <= pair_idx + 1; state <= S_READ;
            end if;

          when S_NEXT_BLOCK =>
            if inverse = '0' then zeta_k <= zeta_k + 1;
            else zeta_k <= zeta_k - 1; end if;
            if block_idx + 1 >= n_blocks then
              block_idx <= (others => '0'); state <= S_NEXT_LAYER;
            else
              block_idx <= block_idx + 1; state <= S_READ;
            end if;

          when S_NEXT_LAYER =>
            if layer = 6 then
              if inverse = '1' then state <= S_SCALE_INIT;
              else state <= S_DONE; end if;
            else
              layer <= layer + 1; state <= S_SETUP_LAYER;
            end if;

          -- INTT scaling: multiply all coeffs by N_INV
          when S_SCALE_INIT =>
            scale_idx <= (others => '0'); state <= S_SCALE_RD;

          when S_SCALE_RD =>
            addr_a <= scale_idx; state <= S_SCALE_WAIT;

          when S_SCALE_WAIT =>
            state <= S_SCALE_MUL;

          when S_SCALE_MUL =>
            scale_prod <= dout_a * N_INV; state <= S_SCALE_WR;

          when S_SCALE_WR =>
            we_a <= '1'; addr_a <= scale_idx;
            din_a <= barrett(scale_prod);
            if scale_idx = 255 then state <= S_DONE;
            else scale_idx <= scale_idx + 1; state <= S_SCALE_RD; end if;

          when S_DONE =>
            done <= '1'; busy <= '0'; state <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
