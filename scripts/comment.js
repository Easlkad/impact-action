// Posts the impact Markdown report as a pull request comment, or updates the
// comment posted by a previous run, so a pull request has a single impact
// comment however many times it is pushed.
//
// Called from actions/github-script, which provides github, context and core.
// It never throws: commenting is optional, and problems such as the
// read-only token of pull requests from forks become warnings, so the
// analysis and the job summary are unaffected.
'use strict';

const fs = require('fs');

// MARKER starts every impact report, and identifies the comment to update.
const MARKER = '<!-- impact-report -->';

// MAX_BODY is GitHub's limit on the length of a comment body.
const MAX_BODY = 65536;

const TRUNCATED = '\n\n_The report was truncated to fit in a comment. The full report is in the job summary._\n';

// commentBody returns the comment for a report: starting with the marker,
// and truncated at a line boundary if it is too long for a comment.
function commentBody(report) {
  let body = report.startsWith(MARKER) ? report : `${MARKER}\n${report}`;
  if (body.length > MAX_BODY) {
    body = body.slice(0, MAX_BODY - TRUNCATED.length);
    const lastLine = body.lastIndexOf('\n');
    if (lastLine > 0) {
      body = body.slice(0, lastLine);
    }
    body += TRUNCATED;
  }
  return body;
}

// commenterLogin returns the login the token comments as. GITHUB_TOKEN cannot
// query its own user, and always comments as github-actions[bot].
async function commenterLogin(github) {
  try {
    const { data } = await github.rest.users.getAuthenticated();
    return data.login;
  } catch {
    return 'github-actions[bot]';
  }
}

// postReport posts or updates the comment, and returns what it did:
// "created", "updated", "skipped" or "failed".
async function postReport({ github, context, core }, reportPath) {
  const pr = context.payload.pull_request;
  if (!pr) {
    core.info('Not a pull request: no comment posted.');
    return 'skipped';
  }

  let body;
  try {
    body = commentBody(fs.readFileSync(reportPath, 'utf8'));
  } catch (err) {
    core.warning(`Impact: cannot read the report ${reportPath}: ${err.message}`);
    return 'failed';
  }

  const { owner, repo } = context.repo;
  const issue_number = pr.number;
  try {
    const login = await commenterLogin(github);
    const comments = await github.paginate(github.rest.issues.listComments, {
      owner,
      repo,
      issue_number,
      per_page: 100,
    });
    // Only our own comments: never edit someone who quoted a report.
    const previous = comments.find(
      (c) => c.user && c.user.login === login && typeof c.body === 'string' && c.body.startsWith(MARKER),
    );
    if (previous) {
      await github.rest.issues.updateComment({ owner, repo, comment_id: previous.id, body });
      core.info(`Updated the impact comment: ${previous.html_url}`);
      return 'updated';
    }
    const { data } = await github.rest.issues.createComment({ owner, repo, issue_number, body });
    core.info(`Posted the impact comment: ${data.html_url}`);
    return 'created';
  } catch (err) {
    let hint = '';
    if (err.status === 403 || err.status === 404) {
      hint =
        ' The token cannot write to this pull request; pull requests from forks get a read-only token.' +
        ' Give the workflow "pull-requests: write", or set comment to false.';
    }
    core.warning(`Impact: could not post the pull request comment (${err.message}).${hint} The report is in the job summary.`);
    return 'failed';
  }
}

module.exports = postReport;
module.exports.commentBody = commentBody;
module.exports.MARKER = MARKER;
module.exports.MAX_BODY = MAX_BODY;
