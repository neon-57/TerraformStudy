import express from 'express';
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { Client } from 'pg';

const app = express();
app.use(express.json());

app.get('/', (req, res) => {
  res.send('Hello, World!');
});

app.get('/db', async (req, res) => {
  try {
    const sm = new SecretsManagerClient({});
    const secret = await sm.send(new GetSecretValueCommand({ SecretId: process.env.DB_SECRET_ARN }));
    const cfg = JSON.parse(secret.SecretString);

    const client = new Client({
      host: cfg.host,
      port: cfg.port,
      user: cfg.username,
      password: cfg.password,
      database: cfg.dbname,
    });
    await client.connect();

    // INSERT サンプル
    await client.query('CREATE TABLE IF NOT EXISTS hits(id SERIAL PRIMARY KEY, ts TIMESTAMP DEFAULT NOW())');
    await client.query('INSERT INTO hits DEFAULT VALUES');

    // SELECT サンプル
    const { rows } = await client.query('SELECT COUNT(*) AS cnt FROM hits');
    await client.end();

    res.json({ count: rows[0].cnt });
  } catch (err) {
    console.error(err);
    res.status(500).send('DB access error');
  }
});

export default app;