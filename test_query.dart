import 'package:supabase/supabase.dart';
import 'dart:io';

Future<void> main() async {
  final client = SupabaseClient(
    'https://mbvahkdwswhcchqsrtrj.supabase.co',
    'sb_publishable_CKI8q91qPj_14atCKG13aQ_9K6on9bV',
  );

  try {
    print('Testing query...');
    // Just fetch ALL contact requests to see what they look like
    final allReqs = await client.from('contact_requests').select('*');
    print('All Reqs: $allReqs');
    
    if (allReqs.isNotEmpty) {
      final req = allReqs[0];
      final myUserId = req['sender_user_id'];
      
      final rows = await client
          .from('contact_requests')
          .select('*, sender:users!contact_requests_sender_user_id_fkey(*), receiver:users!contact_requests_receiver_user_id_fkey(*)')
          .eq('status', 'pending')
          .or('sender_user_id.eq.$myUserId,receiver_user_id.eq.$myUserId');
          
      print('Filtered Reqs: $rows');
    }
  } catch (e) {
    print('Error: $e');
  }
}
