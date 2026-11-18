// Encrypted attachment blobs. The server stores ciphertext only (see
// migrations/004_attachments.sql), in Postgres, on disk or in S3 (blobstore.js) and hands it to the uploader and the
// uploader's contacts, who hold the key inside an end-to-end encrypted message.
import { withTransaction } from './db.js';
import * as v from './validate.js';
import { HttpError } from './validate.js';

/**
 * @param {import('./http.js').Router} router
 */
export function registerAttachmentRoutes(router, { pool, services, limits, config, blobs }) {
  const MIN_BYTES = 40; // secretbox nonce + MAC at least

  router.add(
    'POST',
    '/api/attachments',
    async ({ body, user }) => {
      if (!(await limits.take('upload', user.id))) {
        throw new HttpError(429, 'rate_limited', 'Too many uploads, slow down');
      }
      if (!Buffer.isBuffer(body) || body.length < MIN_BYTES) {
        throw new HttpError(400, 'invalid_input', 'Upload the encrypted file as the request body');
      }
      const inline = blobs.kind === 'postgres';
      // Check and insert under a per-user lock, so parallel uploads can't
      // each pass the quota check.
      const rows = await withTransaction(pool, async (client) => {
        await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`upload:${user.id}`]);
        const { rows: used } = await client.query(
          'SELECT COALESCE(sum(size), 0)::bigint AS n FROM attachments WHERE uploader_id = $1 AND expires_at > now()',
          [user.id],
        );
        if (Number(used[0].n) + body.length > config.attachmentQuotaBytes) {
          throw new HttpError(413, 'quota_exceeded', 'Your storage for pending attachments is full');
        }
        const res = await client.query(
          `INSERT INTO attachments (uploader_id, size, data, storage, expires_at)
           VALUES ($1, $2, $3, $4, now() + make_interval(days => $5))
           RETURNING id, size, expires_at`,
          [user.id, body.length, inline ? body : null, blobs.kind, config.attachmentTtlDays],
        );
        return res.rows;
      });
      if (!inline) {
        try {
          await blobs.put(rows[0].id, body);
        } catch (err) {
          await pool.query('DELETE FROM attachments WHERE id = $1', [rows[0].id]);
          throw err;
        }
      }
      return { status: 201, body: { id: rows[0].id, size: rows[0].size, expires_at: rows[0].expires_at } };
    },
    { rawBody: config.attachmentMaxBytes },
  );

  /** The ciphertext, for its uploader and the uploader's contacts. */
  router.add('GET', '/api/attachments/:id', async ({ params, user }) => {
    const id = v.uuid(params.id);
    const { rows } = await pool.query(
      'SELECT uploader_id, data, storage FROM attachments WHERE id = $1 AND expires_at > now()',
      [id],
    );
    const row = rows[0];
    const allowed = row && (row.uploader_id === user.id || (await services.areContacts(row.uploader_id, user.id)));
    if (!allowed) throw new HttpError(404, 'not_found', 'This attachment has expired or is not available');
    const bytes = row.storage === 'postgres' ? row.data : await blobs.get(id);
    if (!bytes) throw new HttpError(404, 'not_found', 'This attachment has expired or is not available');
    return bytes;
  });

  router.add('DELETE', '/api/attachments/:id', async ({ params, user }) => {
    const id = v.uuid(params.id);
    const { rows } = await pool.query(
      'DELETE FROM attachments WHERE id = $1 AND uploader_id = $2 RETURNING storage',
      [id, user.id],
    );
    if (!rows[0]) throw new HttpError(404, 'not_found', 'No such attachment');
    if (rows[0].storage !== 'postgres') await blobs.delete(id);
  });
}
