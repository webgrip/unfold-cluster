import { readFile } from 'node:fs/promises';

const clickupApi = 'https://api.clickup.com/api/v2';
const kubernetesApi = 'https://kubernetes.default.svc';
const serviceAccount = '/var/run/secrets/kubernetes.io/serviceaccount';
const events = ['taskAssigneeUpdated', 'taskStatusUpdated', 'taskUpdated'];
const { CLICKUP_TOKEN, WORKSPACE_ID, LIST_ID, ENDPOINT, SECRET_NAME, DEPLOYMENT } = process.env;

const namespace = (await readFile(`${serviceAccount}/namespace`, 'utf8')).trim();
const kubernetesToken = (await readFile(`${serviceAccount}/token`, 'utf8')).trim();
const encode = (value) => Buffer.from(value, 'utf8').toString('base64');
const decode = (value) => (value ? Buffer.from(value, 'base64').toString('utf8') : undefined);

async function clickup(method, path, body) {
  const response = await fetch(clickupApi + path, {
    method,
    headers: { Authorization: CLICKUP_TOKEN, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`ClickUp ${method} ${path} answered ${response.status}`);
  return response.json();
}

async function kubernetes(method, path, body, contentType = 'application/json') {
  const response = await fetch(kubernetesApi + path, {
    method,
    headers: { Authorization: `Bearer ${kubernetesToken}`, 'Content-Type': contentType },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (method === 'GET' && response.status === 404) return undefined;
  if (!response.ok) throw new Error(`Kubernetes ${method} ${path} answered ${response.status}`);
  return response.json();
}

const secretsPath = `/api/v1/namespaces/${namespace}/secrets`;
const stored = await kubernetes('GET', `${secretsPath}/${SECRET_NAME}`);
const storedId = decode(stored?.data?.['webhook-id']);
const { webhooks = [] } = await clickup('GET', `/team/${WORKSPACE_ID}/webhook`);
const ours = webhooks.filter((webhook) => webhook.endpoint === ENDPOINT);
const kept = ours.find((webhook) => webhook.id === storedId);

if (kept) {
  if (kept.health?.status === 'suspended') {
    await clickup('PUT', `/webhook/${kept.id}`, { endpoint: ENDPOINT, events, status: 'active' });
    console.log(`reactivated the suspended ClickUp webhook ${kept.id}`);
  } else {
    console.log(`the ClickUp webhook ${kept.id} for ${ENDPOINT} is ${kept.health?.status ?? 'present'}`);
  }
  process.exit(0);
}

for (const orphan of ours) {
  await clickup('DELETE', `/webhook/${orphan.id}`);
  console.log(`deleted the ClickUp webhook ${orphan.id}, whose secret is not stored`);
}

const created = await clickup('POST', `/team/${WORKSPACE_ID}/webhook`, { endpoint: ENDPOINT, events, list_id: Number(LIST_ID) });
const data = { PLOEG_CLICKUP_SECRET: encode(created.webhook.secret), 'webhook-id': encode(created.id) };
if (stored) {
  await kubernetes('PATCH', `${secretsPath}/${SECRET_NAME}`, { data }, 'application/merge-patch+json');
} else {
  await kubernetes('POST', secretsPath, { apiVersion: 'v1', kind: 'Secret', metadata: { name: SECRET_NAME }, type: 'Opaque', data });
}
console.log(`registered the ClickUp webhook ${created.id} for ${ENDPOINT} and stored its secret in ${SECRET_NAME}`);

await kubernetes(
  'PATCH',
  `/apis/apps/v1/namespaces/${namespace}/deployments/${DEPLOYMENT}`,
  { spec: { template: { metadata: { annotations: { 'unfold-staging.webgrip.dev/clickup-webhook': created.id } } } } },
  'application/merge-patch+json',
);
console.log(`restarted ${DEPLOYMENT} so it reads the new secret`);
