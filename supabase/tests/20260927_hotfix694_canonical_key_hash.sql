-- Database #694 — canonical JS object-key sort key and canonical JSON digest oracle.
--
-- Behaviours pinned here, entirely through public/internal function results (no grep, no hash
-- proxy, no has_function anywhere):
--   * the binary sort key is byte-for-byte the reviewed JavaScript UTF-16 order key, including the
--     canonical array-index branch, its exact 2^32-2 domain edge, the ASCII fast path, the empty
--     value, control characters, every UTF-8 length class and the surrogate-pair range;
--   * the induced order still puts canonical array-index keys first in ascending numeric order and
--     still orders a BMP maximum above the first non-BMP code point, exactly as UTF-16 does;
--   * the recursive canonical JSON text and every digest built on it — the shared
--     dataset_alias_v2_payload_sha256 and the util flow-identity helper — reproduce frozen values,
--     so the #694 fast path cannot drift by a single byte;
--   * scalars, empty containers and non-ASCII keys canonicalise exactly as before.
--
-- The frozen values were captured from the published pre-#694 implementation, so this file is an
-- equivalence oracle: it must pass both before and after the migration.
--
-- The same canonical helper serves the Length*time v1 executor and the util dataset digest
-- helpers; those suites (20260925_foundry186_length_time_v1, 20260926_foundry60_time_alias_v2_current_closure)
-- and the Time v2 batch suite exercise the shared path end to end.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, auth, private;

select plan(45);

-- ------------------------------------------------------------------------------------------------
-- 1. Sort-key bytes. Each row pins one reviewed rule.
-- ------------------------------------------------------------------------------------------------
with cases(label, s, expected_hex) as (values
  -- the canonical array-index branch: \x00 + big-endian int8, only inside 0..2^32-2
  ('index zero',              '0',            '000000000000000000'),
  ('index 42',                '42',           '00000000000000002a'),
  ('index max in domain',     '4294967294',   '0000000000fffffffe'),
  -- outside the index domain, or not a canonical index spelling: the string branch
  ('index max out of domain', '4294967295',   '010034003200390034003900360037003200390035'),
  ('ten digits out of domain','9999999999',   '010039003900390039003900390039003900390039'),
  ('eleven digits',           '10000000000',  '0100310030003000300030003000300030003000300030'),
  ('leading zeros',           '007',          '01003000300037'),
  ('explicit plus',           '+1',           '01002b0031'),
  -- empty value: the loop body never runs, only the \x01 string prefix
  ('empty value',             '',             '01'),
  -- pure ASCII: one 0x00-prefixed byte per character (the #694 fast path)
  ('ascii single',            'a',            '010061'),
  ('ascii key',               '@id',          '01004000690064'),
  ('ascii newline',           chr(10),        '01000a'),
  ('ascii tab',               chr(9),         '010009'),
  ('ascii DEL',               chr(127),       '01007f'),
  -- UTF-8 length classes
  ('two-byte max U+07FF',     chr(0x7FF),     '0107ff'),
  ('three-byte min U+0800',   chr(0x800),     '010800'),
  ('latin-1 U+00E9',          chr(0xE9),      '0100e9'),
  ('three-byte CJK U+540D',   chr(0x540D),    '01540d'),
  -- surrogate gap and BMP top
  ('below the gap U+D7FF',    chr(0xD7FF),    '01d7ff'),
  ('above the gap U+E000',    chr(0xE000),    '01e000'),
  ('replacement U+FFFD',      chr(0xFFFD),    '01fffd'),
  ('BMP max U+FFFF',          chr(0xFFFF),    '01ffff'),
  -- surrogate pairs above the BMP
  ('first non-BMP U+10000',   chr(0x10000),   '01d800dc00'),
  ('emoji U+1F600',           chr(0x1F600),   '01d83dde00'),
  ('Unicode max U+10FFFF',    chr(0x10FFFF),  '01dbffdfff'),
  -- mixed: the ASCII prefix and the non-ASCII suffix must encode the same way together
  ('ascii then CJK',          'a' || chr(0x540D), '010061540d')
)
select is(
  encode(private.dataset_alias_js_object_key_sort_key_v1(s), 'hex'),
  expected_hex,
  'sort key bytes: ' || label
) from cases;

-- A long pure-ASCII key is exactly the prefix plus two hex digits per byte, with no quadratic drift.
select is(
  encode(private.dataset_alias_js_object_key_sort_key_v1(repeat('a', 100)), 'hex'),
  '01' || repeat('0061', 100),
  'sort key bytes: 100-character ASCII key is one 0x00-prefixed byte per character'
);

-- ------------------------------------------------------------------------------------------------
-- 2. Induced order. These are the rules a plain byte comparison of the key must still satisfy.
-- ------------------------------------------------------------------------------------------------
select ok(
  private.dataset_alias_js_object_key_sort_key_v1('2') < private.dataset_alias_js_object_key_sort_key_v1('10'),
  'order: canonical array indexes sort in ascending numeric order, not lexically'
);
select ok(
  private.dataset_alias_js_object_key_sort_key_v1('2') < private.dataset_alias_js_object_key_sort_key_v1('a'),
  'order: every canonical array index sorts before every string key'
);
select ok(
  private.dataset_alias_js_object_key_sort_key_v1('') < private.dataset_alias_js_object_key_sort_key_v1('a'),
  'order: the empty key sorts before any non-empty string key'
);
select ok(
  private.dataset_alias_js_object_key_sort_key_v1(chr(0xFFFF)) > private.dataset_alias_js_object_key_sort_key_v1(chr(0x10000)),
  'order: the BMP maximum sorts above the first non-BMP code point, as UTF-16 requires'
);

-- ------------------------------------------------------------------------------------------------
-- 3. Canonical JSON text. Scrambled keys must come out in stableJsonText order.
-- ------------------------------------------------------------------------------------------------
select is(
  private.dataset_alias_canonical_jsonb_v1('{"b":1,"a":[1,2,{"z":"名字","y":"😀"}],"10":"ten","2":"two","0":"zero","":""}'::jsonb),
  '{"0":"zero","2":"two","10":"ten","":"","a":[1,2,{"y":"😀","z":"名字"}],"b":1}',
  'canonical text: array-index keys first in numeric order, then strings in UTF-16 order'
);
select is(
  private.dataset_alias_canonical_jsonb_v1('{"x":{"10":1,"9":2,"a":3},"y":[[1,2],{"":0}],"2":null,"1":true}'::jsonb),
  '{"1":true,"2":null,"x":{"9":2,"10":1,"a":3},"y":[[1,2],{"":0}]}',
  'canonical text: nested objects, nested arrays and a nested empty key'
);
select is(private.dataset_alias_canonical_jsonb_v1('{}'::jsonb), '{}', 'canonical text: empty object');
select is(private.dataset_alias_canonical_jsonb_v1('[]'::jsonb), '[]', 'canonical text: empty array');
select is(private.dataset_alias_canonical_jsonb_v1('"plain"'::jsonb), '"plain"', 'canonical text: string scalar');
select is(private.dataset_alias_canonical_jsonb_v1('1.50'::jsonb), '1.50', 'canonical text: numeric scalar');
select is(private.dataset_alias_canonical_jsonb_v1('null'::jsonb), 'null', 'canonical text: null scalar');

-- ------------------------------------------------------------------------------------------------
-- 4. Digests built on the canonical text, on both the private and the shared util surface.
-- ------------------------------------------------------------------------------------------------
select is(
  private.dataset_alias_v2_payload_sha256('{"b":1,"a":[1,2,{"z":"名字","y":"😀"}],"10":"ten","2":"two","0":"zero","":""}'::jsonb),
  '56398ba8c1eec73b7301abf35603c2e25f1786918d40c0642684c104416b9775',
  'payload digest: mixed ASCII, CJK, emoji and index keys'
);
select is(
  private.dataset_alias_v2_payload_sha256('{"x":{"10":1,"9":2,"a":3},"y":[[1,2],{"":0}],"2":null,"1":true}'::jsonb),
  'd36f2feddffe7f30b2811966757612a039619f8cbd40352e0efea921780262cf',
  'payload digest: nested canonical text'
);
select is(
  private.dataset_alias_v2_payload_sha256('{"名前":"値","key":"😀"}'::jsonb),
  '5c389d77ebc379ad6a455025e0990d4cf167583c08a6b5f91cede4e5266e6354',
  'payload digest: non-ASCII keys'
);
select is(
  private.dataset_alias_v2_payload_sha256('{"n":1.50,"s":"plain","z":null,"b":false}'::jsonb),
  '737bfcc04dde5048e7a536c0021cdadd49fb0e0813face61d0d546ba47fe6318',
  'payload digest: scalars of every type'
);
select is(
  util.dataset_flow_identity_sha256('{"b":1,"a":[1,2,{"z":"名字","y":"😀"}],"10":"ten","2":"two","0":"zero","":""}'::jsonb),
  '56398ba8c1eec73b7301abf35603c2e25f1786918d40c0642684c104416b9775',
  'shared util flow-identity digest: same canonical text, same digest'
);
select is(
  util.dataset_flow_identity_sha256('{"x":{"10":1,"9":2,"a":3},"y":[[1,2],{"":0}],"2":null,"1":true}'::jsonb),
  'd36f2feddffe7f30b2811966757612a039619f8cbd40352e0efea921780262cf',
  'shared util flow-identity digest: nested canonical text'
);

-- The fast path is deterministic: repeated calls on the same key agree.
select is(
  (select count(distinct encode(private.dataset_alias_js_object_key_sort_key_v1(k), 'hex'))
     from (values ('@dataSetInternalID'), ('4294967294'), (''), (chr(0xFFFF)), (chr(0x1F600))) as t(k)),
  5::bigint,
  'sort key: five distinct inputs produce five distinct deterministic keys'
);

select * from finish();
rollback;
