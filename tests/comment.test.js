// Tests of scripts/comment.js with a fake GitHub client.
//
// Usage: node --test tests/
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const postReport = require('../scripts/comment.js');
const { commentBody, MARKER, MAX_BODY } = postReport;

const REPORT = `${MARKER}\n## Impact Analysis\n\n**Risk:** LOW (4/100)\n`;

function writeReport(content = REPORT) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'impact-comment-'));
  const file = path.join(dir, 'impact-report.md');
  fs.writeFileSync(file, content);
  return file;
}

// fakeGitHub returns a client holding existing comments, recording calls.
// login is the user the token authenticates as; null makes
// getAuthenticated fail, as it does for GITHUB_TOKEN. failWith makes the
// comment API calls fail with that HTTP status.
function fakeGitHub({ comments = [], login = null, failWith = null } = {}) {
  const calls = [];
  const fail = () => {
    if (failWith) {
      const err = new Error(`HTTP ${failWith}`);
      err.status = failWith;
      throw err;
    }
  };
  const github = {
    calls,
    rest: {
      users: {
        getAuthenticated: async () => {
          if (!login) {
            const err = new Error('Resource not accessible by integration');
            err.status = 403;
            throw err;
          }
          return { data: { login } };
        },
      },
      issues: {
        listComments: async () => ({ data: comments }),
        createComment: async (args) => {
          fail();
          calls.push(['create', args]);
          return { data: { html_url: 'https://github.com/o/r/pull/7#issuecomment-new' } };
        },
        updateComment: async (args) => {
          fail();
          calls.push(['update', args]);
          return { data: {} };
        },
      },
    },
    paginate: async (method, args) => {
      fail();
      calls.push(['list', args]);
      return (await method(args)).data;
    },
  };
  return github;
}

function fakeCore() {
  const core = { infos: [], warnings: [] };
  core.info = (m) => core.infos.push(m);
  core.warning = (m) => core.warnings.push(m);
  return core;
}

const context = {
  repo: { owner: 'o', repo: 'r' },
  payload: { pull_request: { number: 7 } },
};

const bot = { login: 'github-actions[bot]' };

test('creates a comment when there is none', async () => {
  const github = fakeGitHub({ comments: [{ id: 1, user: bot, body: 'LGTM' }] });
  const core = fakeCore();
  assert.equal(await postReport({ github, context, core }, writeReport()), 'created');
  assert.deepEqual(github.calls, [
    ['list', { owner: 'o', repo: 'r', issue_number: 7, per_page: 100 }],
    ['create', { owner: 'o', repo: 'r', issue_number: 7, body: REPORT }],
  ]);
  assert.deepEqual(core.warnings, []);
});

test('updates the previous report comment', async () => {
  const github = fakeGitHub({
    comments: [
      { id: 1, user: { login: 'alice' }, body: 'Please look at the risk' },
      { id: 2, user: bot, body: `${MARKER}\n## Impact Analysis\nold`, html_url: 'u' },
    ],
  });
  assert.equal(await postReport({ github, context, core: fakeCore() }, writeReport()), 'updated');
  assert.deepEqual(github.calls.at(-1), ['update', { owner: 'o', repo: 'r', comment_id: 2, body: REPORT }]);
});

test("does not edit other users' comments that contain a report", async () => {
  const github = fakeGitHub({
    comments: [{ id: 3, user: { login: 'alice' }, body: `${MARKER}\nquoted report` }],
  });
  assert.equal(await postReport({ github, context, core: fakeCore() }, writeReport()), 'created');
});

test('with a personal token, finds the comments of that user', async () => {
  const github = fakeGitHub({
    login: 'release-bot',
    comments: [
      { id: 4, user: bot, body: `${MARKER}\nfrom GITHUB_TOKEN` },
      { id: 5, user: { login: 'release-bot' }, body: `${MARKER}\nfrom the PAT` },
    ],
  });
  assert.equal(await postReport({ github, context, core: fakeCore() }, writeReport()), 'updated');
  assert.equal(github.calls.at(-1)[1].comment_id, 5);
});

test('a read-only token is a warning, not a failure', async () => {
  const github = fakeGitHub({ failWith: 403 });
  const core = fakeCore();
  assert.equal(await postReport({ github, context, core }, writeReport()), 'failed');
  assert.equal(core.warnings.length, 1);
  assert.match(core.warnings[0], /pull requests from forks get a read-only token/);
  assert.match(core.warnings[0], /The report is in the job summary/);
});

test('other API errors are warnings too', async () => {
  const github = fakeGitHub({ failWith: 500 });
  const core = fakeCore();
  assert.equal(await postReport({ github, context, core }, writeReport()), 'failed');
  assert.doesNotMatch(core.warnings[0], /forks/);
});

test('a missing report is a warning', async () => {
  const core = fakeCore();
  assert.equal(await postReport({ github: fakeGitHub(), context, core }, '/no/such/report.md'), 'failed');
  assert.match(core.warnings[0], /cannot read the report/);
});

test('outside a pull request, nothing is posted', async () => {
  const github = fakeGitHub();
  const result = await postReport({ github, context: { ...context, payload: {} }, core: fakeCore() }, writeReport());
  assert.equal(result, 'skipped');
  assert.deepEqual(github.calls, []);
});

test('commentBody adds the marker when missing', () => {
  assert.equal(commentBody('## Impact Analysis\n'), `${MARKER}\n## Impact Analysis\n`);
  assert.equal(commentBody(REPORT), REPORT);
});

test('commentBody truncates long reports at a line boundary', () => {
  const line = '- `Function` — direct — `file.go`\n';
  const body = commentBody(MARKER + '\n' + line.repeat(5000));
  assert.ok(body.length <= MAX_BODY, `length ${body.length}`);
  assert.ok(body.startsWith(MARKER));
  assert.match(body, /`file.go`\n\n_The report was truncated to fit in a comment\. The full report is in the job summary\._\n$/);
});
