// Checks on the JSON of `docker volume inspect` and `docker inspect`, for the
// managed-volume gate and the ownership proofs of the legacy session-volume
// and Compose-stack migration. The rules are in
// docs/contributing/project-identity.md.
//
// Each check takes the parsed inspect object and returns a boolean. aic
// passes the inspect output on argv; lib/cli.mjs exits 0 when the check
// holds, 1 when it does not, and 2 when the JSON does not parse.
//
// Only node: built-ins, no packages.

// The two paths where aicontainer mounts the session volume.
const SESSION_ROOTS = new Set([
  '/home/vscode/.claude-sessions',
  '/home/vscode/.aic-sessions',
]);

// The fixed managed sidecars. Only these may have no workspace label.
const AUXILIARY_SERVICES = new Set(['socket-proxy', 'aic-auth-sync', 'aic-seed-sanitizer']);

const labelsOf = container => container && container.Config && container.Config.Labels;

// An ordinary local volume: Driver "local" and no driver options. A local
// volume with options such as type=none,o=bind is a host bind.
export function volumeIsSafe(volume) {
  const options = volume && volume.Options;
  const emptyOptions = options == null ||
    (typeof options === 'object' && !Array.isArray(options) && Object.keys(options).length === 0);
  if (!volume || volume.Driver !== 'local' || !emptyOptions) return false;
  return true;
}

// The container has the exact workspace label and the exact Compose project
// label, and mounts the named volume `name` at a session root.
export function ownsSessionVolume(container, workspace, project, name) {
  const labels = labelsOf(container);
  const mounts = container && container.Mounts;
  const owned = labels &&
    labels['devcontainer.local_folder'] === workspace &&
    labels['com.docker.compose.project'] === project &&
    Array.isArray(mounts) && mounts.some((mount) =>
      mount && mount.Type === 'volume' &&
      mount.Name === name && SESSION_ROOTS.has(mount.Destination));
  if (!owned) return false;
  return true;
}

// The container mounts the named volume `name` and has the exact workspace
// label and the exact Compose project label. A container that does not
// mount the volume as a named volume fails too, so the proof never rests on
// the Docker filter alone.
export function volumeUserIsOwner(container, workspace, project, name) {
  const labels = labelsOf(container);
  const mounts = container && container.Mounts;
  const usesVolume = Array.isArray(mounts) && mounts.some((mount) =>
    mount && mount.Type === 'volume' && mount.Name === name);
  if (!usesVolume) return false;
  const sameOwner = labels &&
    labels['devcontainer.local_folder'] === workspace &&
    labels['com.docker.compose.project'] === project;
  if (!sameOwner) return false;
  return true;
}

// The container has the exact workspace label and the exact Compose project
// label.
export function containerIsOwned(container, workspace, project) {
  const labels = labelsOf(container);
  const owned = labels &&
    labels['devcontainer.local_folder'] === workspace &&
    labels['com.docker.compose.project'] === project;
  if (!owned) return false;
  return true;
}

// The container is a managed sidecar of the Compose project: it has no
// workspace label, and its service is in AUXILIARY_SERVICES.
export function isAuxiliaryContainer(container, project) {
  const labels = labelsOf(container);
  const auxiliary = labels &&
    labels['com.docker.compose.project'] === project &&
    !labels['devcontainer.local_folder'] &&
    AUXILIARY_SERVICES.has(labels['com.docker.compose.service']);
  if (!auxiliary) return false;
  return true;
}
