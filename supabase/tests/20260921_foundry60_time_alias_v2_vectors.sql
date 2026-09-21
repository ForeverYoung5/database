-- Foundry #60 / Database #673 — shared decimal parity vectors (root-generated list).
--
-- Source: root's credential-free vector list, sha256
-- 4d3f6b907a187c3266c9e6d3b599e96a408694d03baf85c19cf5e6a867e16112: 123 vectors, of which
-- 121 are text literals asserted below (all 92 real stored exponent spellings, oracle products from an
-- independent Python Decimal at precision 256, bounds and refusals). The remaining 2 probes carry a
-- null or JSON-number `input`: the database helpers are text-typed, so a non-text probe cannot reach them by
-- construction and is excluded from the projection (the CLI side asserts those). The CLI owner consumes the
-- identical file, so both sides are compared on their actual acceptance sets and exact desired strings.
-- This suite is a faithful projection of `supabase/tests/fixtures/alias-v2-decimal-parity-vectors.json`.
--
-- v1 grammar, rendering and constants stay untouched.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, private;

select plan(4);

create temp table v2_parity_expectations (
  input text primary key,
  accepted boolean not null,
  desired text
) on commit drop;

insert into v2_parity_expectations (input, accepted, desired) values
      ('-0', true, '0'),      ('-0.0', true, '0'),      ('-1.5e-2', true, '-0.00000171232876712328765'),      ('0', true, '0'),      ('0.0', true, '0'),      ('0.0000000000000000000000000000000000000000000000000000000000001', true, '0.000000000000000000000000000000000000000000000000000000000000000011415525114155251'),      ('1', true, '0.00011415525114155251'),      ('1.0', true, '0.00011415525114155251'),      ('1.03E-4', true, '0.00000001175799086757990853'),      ('1.06E-4', true, '0.00000001210045662100456606'),      ('1.18E-4', true, '0.00000001347031963470319618'),      ('1.18E-7', true, '0.00000000001347031963470319618'),      ('1.28E-4', true, '0.00000001461187214611872128'),      ('1.35E-4', true, '0.00000001541095890410958885'),      ('1.383E-5', true, '0.0000000015787671232876712133'),      ('1.39E-4', true, '0.00000001586757990867579889'),      ('1.422E-4', true, '0.000000016232876712328766922'),      ('1.571E-4', true, '0.000000017933789954337899321'),      ('1.77E-4', true, '0.00000002020547945205479427'),      ('1.836E-5', true, '0.0000000020958904109589040836'),      ('1.87E-5', true, '0.000000002134703196347031937'),      ('1.91E-6', true, '0.0000000002180365296803652941'),      ('1.97E-4', true, '0.00000002248858447488584447'),      ('1.9E-5', true, '0.00000000216894977168949769'),      ('1.9e-05', true, '0.00000000216894977168949769'),      ('1234567890123456789012345678901234567890123456789012345678901234', true, '140932407548339814349737881434973788143497378814349737881434.97372331585771479734'),      ('1E+01', true, '0.0011415525114155251'),      ('1e-30', true, '0.00000000000000000000000000000000011415525114155251'),      ('1e30', true, '114155251141552510000000000'),      ('2.009E-5', true, '0.0000000022933789954337899259'),      ('2.0E-4', true, '0.000000022831050228310502'),      ('2.14E-4', true, '0.00000002442922374429223714'),      ('2.14E-5', true, '0.000000002442922374429223714'),      ('2.15E-4', true, '0.00000002454337899543378965'),      ('2.21E-5', true, '0.000000002522831050228310471'),      ('2.275E-4', true, '0.000000025970319634703196025'),      ('2.43E-6', true, '0.0000000002773972602739725993'),      ('2.44E-5', true, '0.000000002785388127853881244'),      ('2.45E-5', true, '0.000000002796803652968036495'),      ('2.49E-5', true, '0.000000002842465753424657499'),      ('2.59E-5', true, '0.000000002956621004566210009'),      ('2.77E-6', true, '0.0000000003162100456621004527'),      ('2.7e-05', true, '0.00000000308219178082191777'),      ('2.88E-5', true, '0.000000003287671232876712288'),      ('2.94E-4', true, '0.00000003356164383561643794'),      ('2.9999999999999997e-05', true, '0.00000000342465753424657495753424657534247'),      ('2e-05', true, '0.0000000022831050228310502'),      ('2e-06', true, '0.00000000022831050228310502'),      ('3.07E-5', true, '0.000000003504566210045662057'),      ('3.0E-6', true, '0.00000000034246575342465753'),      ('3.248E-5', true, '0.0000000037077625570776255248'),      ('3.24E-5', true, '0.000000003698630136986301324'),      ('3.29E-5', true, '0.000000003755707762557077579'),      ('3.2e-05', true, '0.00000000365296803652968032'),      ('3.31E-5', true, '0.000000003778538812785388081'),      ('3.4019E-4', true, '0.0000000388344748858447483769'),      ('3.51E-6', true, '0.0000000004006849315068493101'),      ('3.57E-4', true, '0.00000004075342465753424607'),      ('3.7E-5', true, '0.00000000422374429223744287'),      ('3.98E-5', true, '0.000000004543378995433789898'),      ('3.99E-6', true, '0.0000000004554794520547945149'),      ('4.07E-5', true, '0.000000004646118721461187157'),      ('4.08E-5', true, '0.000000004657534246575342408'),      ('4.14E-6', true, '0.0000000004726027397260273914'),      ('4.22E-5', true, '0.000000004817351598173515922'),      ('4.22E-6', true, '0.0000000004817351598173515922'),      ('4.23E-5', true, '0.000000004828767123287671173'),      ('4.341E-5', true, '0.0000000049554794520547944591'),      ('4.409E-5', true, '0.0000000050331050228310501659'),      ('4.56E-4', true, '0.00000005205479452054794456'),      ('4.65E-4', true, '0.00000005308219178082191715'),      ('4.74E-4', true, '0.00000005410958904109588974'),      ('4.81E-5', true, '0.000000005490867579908675731'),      ('4.92E-4', true, '0.00000005616438356164383492'),      ('4.981E-6', true, '0.00000000056860730593607305231'),      ('5.082E-5', true, '0.0000000058013698630136985582'),      ('5.19E-6', true, '0.0000000005924657534246575269'),      ('5.26E-5', true, '0.000000006004566210045662026'),      ('5.28E-5', true, '0.000000006027397260273972528'),      ('5.31E-5', true, '0.000000006061643835616438281'),      ('5.36E-5', true, '0.000000006118721461187214536'),      ('5.3E-5', true, '0.00000000605022831050228303'),      ('5.48E-5', true, '0.000000006255707762557077548'),      ('5.5e-05', true, '0.00000000627853881278538805'),      ('5.6e-05', true, '0.00000000639269406392694056'),      ('5.915E-4', true, '0.000000067522831050228309665'),      ('6.02E-4', true, '0.00000006872146118721461102'),      ('6.07E-4', true, '0.00000006929223744292237357'),      ('6.17E-4', true, '0.00000007043378995433789867'),      ('6.17E-5', true, '0.000000007043378995433789867'),      ('6.615E-5', true, '0.0000000075513698630136985365'),      ('7.03E-4', true, '0.00000008025114155251141453'),      ('7.136E-5', true, '0.0000000081461187214611871136'),      ('7.17E-7', true, '0.00000000008184931506849314967'),      ('7.56E-4', true, '0.00000008630136986301369756'),      ('7.5E-5', true, '0.00000000856164383561643825'),      ('7.71E-6', true, '0.0000000008801369863013698521'),      ('7.81E-6', true, '0.0000000008915525114155251031'),      ('8.499E-5', true, '0.0000000097020547945205478249'),      ('8.84E-6', true, '0.0000000010091324200913241884'),      ('9.1E-5', true, '0.00000001038812785388127841'),      ('9.423E-4', true, '0.000000107568493150684930173'),      ('9.45E-4', true, '0.00000010787671232876712195'),      ('9.582E-5', true, '0.0000000109383561643835615082'),      ('01E0', false, null),      ('1E030', false, null),      ('1e000', false, null),      ('+1E-4', false, null),      ('.5E-3', false, null),      ('1.E-4', false, null),      ('NaN', false, null),      ('Infinity', false, null),      ('1e31', false, null),      ('1e-31', false, null),      ('1e99999999', false, null),      ('1_000', false, null),      ('0x10', false, null),      (' 1', false, null),      ('1 ', false, null),      ('1e1e1', false, null),      ('99999999999999999999999999999999999999999999999999999999999999999', false, null);

create temp table v2_parity_actual (
  input text primary key,
  accepted boolean,
  desired text,
  raised boolean not null default false
) on commit drop;

do $$
declare
  probe record;
  verdict boolean;
  product text;
begin
  for probe in select * from v2_parity_expectations
  loop
    begin
      execute format('select private.dataset_alias_v2_amount_grammar_ok(%L::text)', probe.input)
        into verdict;
      execute format('select private.dataset_alias_v2_multiply_amount(%L::text, %L::text)',
        probe.input, '0.00011415525114155251')
        into product;
      insert into v2_parity_actual (input, accepted, desired) values (probe.input, verdict, product);
    exception when others then
      insert into v2_parity_actual (input, accepted, desired, raised) values (probe.input, null, null, true);
    end;
  end loop;
end
$$;

select is((select count(*) from v2_parity_expectations), 121::bigint,
  'every text literal of the shared vector list is installed');
select is(
  (select count(*) from v2_parity_expectations where accepted),
  (select count(*) from v2_parity_actual where accepted),
  'the accepted set matches the shared oracle exactly'
);
select is((select count(*) from v2_parity_actual where raised), 0::bigint,
  'every shared vector is evaluated without an exception');
select is(
  (select jsonb_agg(jsonb_build_object('input', input, 'accepted', accepted, 'desired', desired, 'raised', raised) order by input)
     from v2_parity_actual),
  (select jsonb_agg(jsonb_build_object('input', input, 'accepted', accepted, 'desired', desired, 'raised', false) order by input)
     from v2_parity_expectations),
  'every shared vector yields the expected verdict and the expected canonical desired string'
);

select * from finish();
rollback;
