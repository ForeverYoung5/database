-- Foundry #60 / Database #673 — shared math vector parity (root's cross-language review,
-- `/tmp/foundry60-v2-math-parity-review.md`). Generated from the shared credential-free vector list
-- `tiangong-foundry.alias-v2-math-vectors.v1`; the CLI owner consumes the identical list, so the two
-- implementations are compared on actual verdicts and exact resulting strings, never on mirrored regexes.
--
-- The canonical home for that list must be agreed with the CLI owner before delivery (this file is a
-- faithful projection of it for the database-side run).

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, private;

select plan(1);

create temp table v2_vector_expectations (
  input text primary key,
  accepted boolean not null,
  product text
) on commit drop;

insert into v2_vector_expectations (input, accepted, product) values
      ('1', true, '0.00011415525114155251'),
      ('1.0', true, '0.00011415525114155251'),
      ('0', true, '0'),
      ('-0.0', true, '0'),
      ('26.0', true, '0.00296803652968036526'),
      ('0.22917', true, '0.0000261609589041095887167'),
      ('1.18E-7', true, '0.00000000001347031963470319618'),
      ('1.03E-4', true, '0.00000001175799086757990853'),
      ('9.423E-4', true, '0.000000107568493150684930173'),
      ('1e-1', true, '0.000011415525114155251'),
      ('1E+01', true, '0.0011415525114155251'),
      ('01E0', false, null),
      ('1E030', false, null),
      ('1E-31', false, null),
      ('+1', false, null),
      ('.5', false, null),
      ('1.', false, null),
      ('1e1e1', false, null),
      ('Infinity', false, null),
      ('NaN', false, null),
      ('1_000E-4', false, null),
      ('0x10', false, null),
      ('1 ', false, null),
      (' 1', false, null);

create temp table v2_vector_actual (
  input text primary key,
  accepted boolean,
  product text,
  raised boolean not null default false
) on commit drop;

do $$
declare
  probe record;
  verdict boolean;
  product text;
begin
  for probe in select * from v2_vector_expectations
  loop
    begin
      execute format('select private.dataset_alias_v2_amount_grammar_ok(%L::text)', probe.input)
        into verdict;
      execute format(
        'select private.dataset_alias_v2_multiply_amount(%L::text, %L::text)',
        probe.input, '0.00011415525114155251'
      ) into product;
      insert into v2_vector_actual (input, accepted, product) values (probe.input, verdict, product);
    exception when others then
      insert into v2_vector_actual (input, accepted, product, raised) values (probe.input, null, null, true);
    end;
  end loop;
end
$$;

select is(
  (select jsonb_agg(jsonb_build_object('input', input, 'accepted', accepted, 'product', product, 'raised', raised) order by input)
     from v2_vector_actual),
  (select jsonb_agg(jsonb_build_object('input', input, 'accepted', accepted, 'product', product, 'raised', false) order by input)
     from v2_vector_expectations),
  'every shared vector yields the expected verdict and the expected canonical product'
);

select * from finish();
rollback;
