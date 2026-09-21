-- Foundry #60 / Database #673 — v2 exact-numeric helpers (agreement §A1/§A2, root decisions 1–2).
--
-- These helpers are the only numeric entry points the v2 executors will use: bounded exact parsing of the
-- original literals (including the 151 exponent forms that stay byte-identical in `before`), exact
-- multiplication by the fixed approved factor, and canonical plain-decimal rendering for `desired`
-- (no exponent, no `+`, `0` for zero, trailing fractional zeros trimmed). No float path exists anywhere.
--
-- The expected products below were produced by an independent exact-decimal oracle (`decimal.Decimal`),
-- never by hand. Calls run through dynamic SQL so the RED phase reports clean failures instead of aborting
-- the transaction while the helpers do not exist yet.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, private;

select plan(18);

create temp table v2_math_probe (
  label text primary key,
  value text,
  raised boolean not null default false
) on commit drop;

do $$
declare
  probe record;
  value text;
begin
  for probe in
    select * from (values
      ('one',            '1',        '0.00011415525114155251'),
      ('one-trailing',   '1.0',      '0.00011415525114155251'),
      ('exp-1.18E-7',    '1.18E-7',  '0.00011415525114155251'),
      ('exp-1.03E-4',    '1.03E-4',  '0.00011415525114155251'),
      ('exp-9.423E-4',   '9.423E-4', '0.00011415525114155251'),
      ('zero',           '0',        '0.00011415525114155251'),
      ('26-trailing',    '26.0',     '0.00011415525114155251'),
      ('exp-factor',     '1',        '1E-3'),
      ('other-factor',   '1.18E-7',  '0.00011415525114155252')
    ) as t(label, amount, factor)
  loop
    begin
      execute format(
        'select private.dataset_alias_v2_multiply_amount(%L::text, %L::text)',
        probe.amount, probe.factor
      ) into value;
      insert into v2_math_probe (label, value) values (probe.label, value);
    exception when others then
      insert into v2_math_probe (label, value, raised) values (probe.label, null, true);
    end;
  end loop;
end
$$;

select has_function('private', 'dataset_alias_v2_amount_grammar_ok', array['text'], 'grammar guard exists');
select has_function('private', 'dataset_alias_v2_multiply_amount', array['text', 'text'], 'exact multiply helper exists');

select is(
  (select value from v2_math_probe where label = 'one'),
  '0.00011415525114155251', 'integer one derives the canonical trimmed decimal'
);
select is(
  (select value from v2_math_probe where label = 'one-trailing'),
  '0.00011415525114155251', 'trailing-zero one derives the identical canonical text'
);
select is(
  (select value from v2_math_probe where label = 'exp-1.18E-7'),
  '0.00000000001347031963470319618', 'stored 1.18E-7 literal multiplies exactly'
);
select is(
  (select value from v2_math_probe where label = 'exp-1.03E-4'),
  '0.00000001175799086757990853', 'stored 1.03E-4 literal multiplies exactly'
);
select is(
  (select value from v2_math_probe where label = 'exp-9.423E-4'),
  '0.000000107568493150684930173', 'stored 9.423E-4 literal multiplies exactly'
);
select is(
  (select value from v2_math_probe where label = 'zero'),
  '0', 'zero renders as plain zero'
);
select is(
  (select value from v2_math_probe where label = '26-trailing'),
  '0.00296803652968036526', 'a non-unit literal with a trailing zero multiplies and trims'
);

-- The factor is fixed: no exponent factor and no other constant may enter the multiplication.
select is(
  (select value from v2_math_probe where label = 'exp-factor'),
  null, 'an exponent factor yields no product'
);
select is(
  (select value from v2_math_probe where label = 'other-factor'),
  null, 'a factor other than the approved constant yields no product'
);

-- Grammar and bounds: rejected before any allocation, never guessed.
create temp table v2_grammar_probe (
  label text primary key,
  value text,
  raised boolean not null default false
) on commit drop;

do $$
declare
  probe record;
  value boolean;
begin
  for probe in
    select * from (values
      ('bounded-exp',      '1.18E-7'),
      ('negative-bounded', '-0.0E-4'),
      ('out-of-range',     '1.18E-31'),
      ('too-long',         repeat('1', 62) || 'E+30'),
      ('double-exp',       '1e1e1'),
      ('non-finite',       'Infinity'),
      ('separator',        '1_000E-4')
    ) as t(label, literal)
  loop
    begin
      execute format('select private.dataset_alias_v2_amount_grammar_ok(%L::text)', probe.literal)
        into value;
      insert into v2_grammar_probe (label, value) values (probe.label, value::text);
    exception when others then
      insert into v2_grammar_probe (label, value, raised) values (probe.label, null, true);
    end;
  end loop;
end
$$;

select is((select value from v2_grammar_probe where label = 'bounded-exp'), 'true',
  'a bounded exponent literal passes');
select is((select value from v2_grammar_probe where label = 'negative-bounded'), 'true',
  'a bounded negative exponent literal passes');
select is((select value from v2_grammar_probe where label = 'out-of-range'), 'false',
  'an out-of-range exponent is refused');
select is((select value from v2_grammar_probe where label = 'too-long'), 'false',
  'an over-long literal is refused');
select is((select value from v2_grammar_probe where label = 'double-exp'), 'false',
  'a double exponent is refused');
select is((select value from v2_grammar_probe where label = 'non-finite'), 'false',
  'a non-finite literal is refused');
select is((select value from v2_grammar_probe where label = 'separator'), 'false',
  'a digit separator is refused');

select * from finish();
rollback;
