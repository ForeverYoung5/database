-- Foundry #60 / Database #673 — v2 exact-numeric helpers for the current source-hour Time repair.
--
-- These are the only numeric entry points the v2 executors will use. The complete before payload keeps
-- its original literal bytes (including the 151 stored exponent forms), so the parser accepts bounded
-- finite ordinary-decimal and exponent literals and never asks a caller to normalise stored bytes. The
-- multiplication is exact `numeric` (no float path exists in this migration), the factor is the single
-- approved constant of the reviewed 365-day convention, and the desired side renders as canonical plain
-- decimal text: no exponent, no `+`, `0` for zero, trailing fractional zeros trimmed.
--
-- v1 stays untouched: its own grammar, rendering and constants are not referenced or shared here.

-- The reviewed hour-to-year factor (1/8760 of the 365-day convention). One definition, one authority.
create or replace function private.dataset_alias_v2_factor()
returns numeric
language sql
immutable
as $$
  select 0.00011415525114155251::numeric
$$;

alter function private.dataset_alias_v2_factor() owner to postgres;
revoke all on function private.dataset_alias_v2_factor() from public;
comment on function private.dataset_alias_v2_factor() is
  'The single approved v2 Time factor; no plan-provided factor is ever admitted.';

-- Bounded grammar guard for one stored or claimed amount literal. Accepts ordinary decimals and a single
-- bounded exponent (|exponent| <= 30); rejects sign prefixes other than '-', leading/trailing separators,
-- non-finite text, digit separators, length above 64 characters and any malformed exponent structure.
create or replace function private.dataset_alias_v2_amount_grammar_ok(p_amount text)
returns boolean
language sql
immutable
as $$
  select
    p_amount is not null
    and octet_length(p_amount) between 1 and 64
    and p_amount ~ '^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]{1,2})?$'
    and (
      p_amount !~ '[eE]'
      or abs(replace(substring(p_amount from '[eE]([+-]?[0-9]{1,2})$'), '+', '')::integer) <= 30
    )
$$;

alter function private.dataset_alias_v2_amount_grammar_ok(text) owner to postgres;
revoke all on function private.dataset_alias_v2_amount_grammar_ok(text) from public;
comment on function private.dataset_alias_v2_amount_grammar_ok(text) is
  'Bounded exact-literal guard: ordinary decimals plus one exponent of magnitude at most 30.';

-- Canonical rendering of one derived amount: plain decimal text, trailing fractional zeros trimmed and a
-- bare zero for zero. PostgreSQL numerics never render exponent notation, so no reformatting is guessed.
create or replace function private.dataset_alias_v2_render_amount(p_value numeric)
returns text
language sql
immutable
as $$
  select case
    when p_value is null then null
    when trim_scale(p_value) = 0 then '0'
    else trim_scale(p_value)::text
  end
$$;

alter function private.dataset_alias_v2_render_amount(numeric) owner to postgres;
revoke all on function private.dataset_alias_v2_render_amount(numeric) from public;
comment on function private.dataset_alias_v2_render_amount(numeric) is
  'Canonical plain-decimal rendering for v2 desired amounts: trimmed, never exponent, zero as 0.';

-- Exact multiplication of one original literal by the fixed factor. Returns null (never a guess) when the
-- literal falls outside the bounded grammar, when the factor is not the approved constant, or when the
-- canonical output would exceed its bound.
create or replace function private.dataset_alias_v2_multiply_amount(p_amount text, p_factor text)
returns text
language plpgsql
immutable
as $$
declare
  v_output text;
begin
  if p_factor is distinct from private.dataset_alias_v2_factor()::text then
    return null;
  end if;
  if not private.dataset_alias_v2_amount_grammar_ok(p_amount) then
    return null;
  end if;
  v_output := private.dataset_alias_v2_render_amount(p_amount::numeric * private.dataset_alias_v2_factor());
  if v_output is null or octet_length(v_output) > 128 then
    return null;
  end if;
  return v_output;
exception
  when numeric_value_out_of_range then
    return null;
end
$$;

alter function private.dataset_alias_v2_multiply_amount(text, text) owner to postgres;
revoke all on function private.dataset_alias_v2_multiply_amount(text, text) from public;
comment on function private.dataset_alias_v2_multiply_amount(text, text) is
  'Exact decimal multiplication by the approved v2 factor; bounded input, canonical output, null otherwise.';
