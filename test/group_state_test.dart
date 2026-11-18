import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/chat/group_state.dart';

const gid = '00000000-0000-4000-8000-000000000001';
const alice = '00000000-0000-4000-8000-00000000000a';
const bob = '00000000-0000-4000-8000-00000000000b';
const carol = '00000000-0000-4000-8000-00000000000c';
const dan = '00000000-0000-4000-8000-00000000000d';

void main() {
  final created = GroupState.create(id: gid, name: ' Trip ', creator: alice, others: [bob, carol]);
  String nameOf(String u) => {alice: 'Alice', bob: 'Bob', carol: 'Carol', dan: 'Dan'}[u]!;

  test('a new group comes from one of its admins and includes us', () {
    expect(created.name, 'Trip');
    expect(GroupState.accept(null, created, actor: alice, me: bob), same(created));
    expect(GroupState.accept(null, created, actor: carol, me: bob), isNull, reason: 'carol is not an admin');
    expect(GroupState.accept(null, created, actor: alice, me: dan), isNull, reason: 'not addressed to us');
  });

  test('admins change the group; members can only leave', () {
    final renamed = created.rename('Trip 2');
    expect(GroupState.accept(created, renamed, actor: alice, me: bob), same(renamed));
    expect(GroupState.accept(created, renamed, actor: bob, me: carol), isNull, reason: 'bob is not an admin');

    final bobLeft = created.without(bob);
    expect(GroupState.accept(created, bobLeft, actor: bob, me: carol), same(bobLeft));
    final carolOut = created.without(carol);
    expect(GroupState.accept(created, carolOut, actor: bob, me: alice), isNull,
        reason: 'a member cannot remove someone else');
    final sneaky = created.without(bob).setAdmin(carol, true);
    expect(GroupState.accept(created, sneaky, actor: bob, me: alice), isNull,
        reason: 'leaving cannot carry other changes');

    expect(GroupState.accept(renamed, created, actor: alice, me: bob), isNull, reason: 'older revision');
    expect(GroupState.accept(created, created.adding([dan]), actor: dan, me: bob), isNull,
        reason: 'not a member yet');
  });

  test('our own devices are trusted', () {
    final mine = created.adding([dan]);
    expect(GroupState.accept(created, mine, actor: bob, me: bob), same(mine));
  });

  test('concurrent changes by two admins settle on the same state everywhere', () {
    final base = created.setAdmin(bob, true);
    final fromAlice = base.rename('From Alice');
    final fromBob = base.rename('From Bob');
    expect(fromAlice.rev, fromBob.rev);

    GroupState apply(GroupState s, GroupState next, String actor) =>
        GroupState.accept(s, next, actor: actor, me: carol) ?? s;
    final oneWay = apply(apply(base, fromAlice, alice), fromBob, bob);
    final otherWay = apply(apply(base, fromBob, bob), fromAlice, alice);
    expect(oneWay.sameAs(otherWay), isTrue, reason: 'arrival order does not matter');
  });

  test('the longest-standing member takes over when the last admin leaves', () {
    final left = created.without(alice);
    expect(left.members, [bob, carol]);
    expect(left.admins, {bob});
    expect(left.rev, created.rev + 1);
  });

  test('describe says what changed', () {
    expect(created.describe(null, alice, nameOf), ['Alice created the group “Trip”']);
    final next = created.adding([dan]).without(carol).setAdmin(bob, true).rename('Trip!');
    expect(next.describe(created, alice, nameOf), [
      'Alice renamed the group to “Trip!”',
      'Alice added Dan',
      'Alice removed Carol',
      'Bob is now an admin',
    ]);
    expect(created.without(bob).describe(created, bob, nameOf), ['Bob left']);
  });

  test('round trip and validation', () {
    expect(GroupState.fromJson(created.toJson()).sameAs(created), isTrue);
    Map<String, dynamic> j([Map<String, dynamic> over = const {}]) => {...created.toJson(), ...over};
    for (final bad in [
      j({'name': ''}),
      j({'name': 'x' * 65}),
      j({'members': [alice, alice]}),
      j({'admins': [dan]}),
      j({'rev': 0}),
      j({'id': 'not-a-uuid'}),
      j({'members': 'nope'}),
      j({'members': List.generate(65, (i) => '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}')}),
    ]) {
      expect(() => GroupState.fromJson(bad), throwsFormatException, reason: '$bad');
    }
    expect(GroupState.isGroup(created.conversationId), isTrue);
    expect(GroupState.isGroup(alice), isFalse);
    expect(GroupState.idOf(created.conversationId), gid);
  });
}
