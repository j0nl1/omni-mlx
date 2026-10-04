import { useEffect, useRef, useState } from "react";
import { Effect } from "effect";
import { Button } from "@heroui/react/button";
import { TextField } from "@heroui/react/textfield";
import { Input } from "@heroui/react/input";
import { Label } from "@heroui/react/label";
import { AlertDialog } from "@heroui/react/alert-dialog";
import {
  Check,
  Copy,
  KeyRound,
  Laptop,
  Plus,
  RefreshCw,
  Search,
  ShieldCheck,
  Waves,
  X,
} from "lucide-react";
import {
  api,
  type APIError,
  type APIKey,
  type CreatedKey,
  type KeyList,
} from "./api";

import { KeysTable } from "./KeysTable";

export function App() {
  const [catalog, setCatalog] = useState<KeyList>();
  const [error, setError] = useState<string>();
  const [notice, setNotice] = useState<string>();
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [search, setSearch] = useState("");
  const [created, setCreated] = useState<CreatedKey>();
  const [copied, setCopied] = useState(false);
  const [revoking, setRevoking] = useState<APIKey>();
  const lifetime = useRef<AbortController | null>(null);
  const secretInput = useRef<HTMLInputElement>(null);
  const copyTimer = useRef<ReturnType<typeof setTimeout> | undefined>(
    undefined,
  );

  function run<A>(
    work: Effect.Effect<A, APIError>,
    onSuccess: (result: A) => void,
    onDone?: () => void,
  ) {
    const signal = lifetime.current?.signal;
    void Effect.runPromise(
      work.pipe(
        Effect.match({
          onFailure: (e) => {
            setError(e.message);
            onDone?.();
          },
          onSuccess: (result) => {
            onSuccess(result);
            onDone?.();
          },
        }),
      ),
      { signal },
    ).catch(() => {
      /* Unmount interrupts requests without updating the screen. */
    });
  }
  function refresh() {
    setLoading(true);
    setError(undefined);
    run(api.list(), setCatalog, () => setLoading(false));
  }
  useEffect(() => {
    lifetime.current = new AbortController();
    refresh();
    return () => {
      lifetime.current?.abort();
      clearTimeout(copyTimer.current);
    };
  }, []);

  function create() {
    if (!name.trim() || busy || created) return;
    setBusy(true);
    setError(undefined);
    setNotice(undefined);
    run(
      api.create(name.trim()),
      (result) => {
        setCreated(result);
        setCreating(false);
        setName("");
        setCopied(false);
        setCatalog(
          (current) =>
            current && { ...current, data: [result.key, ...current.data] },
        );
      },
      () => setBusy(false),
    );
  }
  function revoke() {
    if (!revoking || busy) return;
    const key = revoking;
    setBusy(true);
    setError(undefined);
    run(
      api.revoke(key.id),
      () => {
        setRevoking(undefined);
        if (created?.key.id === key.id) setCreated(undefined);
        setNotice(
          `“${key.name}” was revoked. It can no longer access the audio API.`,
        );
        refresh();
      },
      () => setBusy(false),
    );
  }
  async function copySecret() {
    if (!created) return;
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(created.secret);
      } else {
        const input = secretInput.current;
        if (!input) throw new Error("The key field is unavailable.");
        input.focus();
        input.select();
        if (!document.execCommand("copy")) {
          throw new Error("Clipboard access is unavailable.");
        }
      }
      setCopied(true);
      clearTimeout(copyTimer.current);
      copyTimer.current = setTimeout(() => setCopied(false), 3000);
    } catch {
      secretInput.current?.focus();
      secretInput.current?.select();
      setError(
        "Clipboard access is unavailable. The key is selected; copy it manually before dismissing it.",
      );
    }
  }

  const keys = catalog?.data ?? [];
  const active = keys.filter((key) => key.revoked_at === undefined).length;
  const filtered = keys.filter((key) =>
    `${key.name} ${key.prefix}`.toLowerCase().includes(search.toLowerCase()),
  );

  return (
    <div className="app-shell">
      <header className="topbar">
        <a className="brand" href="/" aria-label="omni-mlx home">
          <Waves size={25} strokeWidth={2} aria-hidden="true" />
          <span>omni-mlx</span>
        </a>
        <span className="local-tag">
          <Laptop size={15} aria-hidden="true" /> Local administration
        </span>
      </header>
      <main>
        <div className="page-heading">
          <div>
            <h1>API keys</h1>
            <p>Give your applications access to speech and transcription.</p>
          </div>
          <Button
            onPress={() => {
              setCreating(true);
              setError(undefined);
            }}
            isDisabled={creating || !!created || !catalog || busy || loading}
          >
            <Plus size={17} aria-hidden="true" /> Create key
          </Button>
        </div>

        {error && (
          <div className="message error" role="alert">
            <span>{error}</span>
            <Button
              variant="ghost"
              size="sm"
              onPress={refresh}
              isDisabled={busy || loading}
            >
              Retry
            </Button>
          </div>
        )}
        {notice && (
          <div className="message success" role="status">
            <Check size={17} aria-hidden="true" />
            <span>{notice}</span>
            <Button
              variant="ghost"
              size="sm"
              isIconOnly
              aria-label="Dismiss notification"
              onPress={() => setNotice(undefined)}
            >
              <X size={16} />
            </Button>
          </div>
        )}

        {creating && (
          <section className="create-panel" aria-labelledby="create-heading">
            <div>
              <h2 id="create-heading">Create an API key</h2>
              <p>Name it after the application that will use it.</p>
            </div>
            <form
              onSubmit={(event) => {
                event.preventDefault();
                create();
              }}
            >
              <TextField
                value={name}
                onChange={setName}
                isRequired
                autoFocus
                isDisabled={busy}
                className="name-field"
              >
                <Label>Key name</Label>
                <Input
                  placeholder="e.g. Local engine"
                  maxLength={80}
                  autoComplete="off"
                />
              </TextField>
              <div className="form-actions">
                <Button
                  variant="secondary"
                  onPress={() => {
                    setCreating(false);
                    setName("");
                  }}
                  isDisabled={busy}
                >
                  Cancel
                </Button>
                <Button
                  type="submit"
                  isPending={busy}
                  isDisabled={!name.trim() || loading}
                >
                  Generate key
                </Button>
              </div>
            </form>
          </section>
        )}

        {created && (
          <section className="secret-panel" aria-labelledby="secret-heading">
            <div className="secret-heading">
              <ShieldCheck size={21} aria-hidden="true" />
              <div>
                <h2 id="secret-heading">“{created.key.name}” is ready</h2>
                <p>Copy this key now. You won’t be able to see it again.</p>
              </div>
            </div>
            <div className="secret-copy">
              <input
                ref={secretInput}
                aria-label="New API key secret"
                readOnly
                value={created.secret}
                spellCheck={false}
              />
              <Button variant="secondary" onPress={() => void copySecret()}>
                {copied ? <Check size={16} /> : <Copy size={16} />}
                {copied ? "Copied" : "Copy key"}
              </Button>
            </div>
            <div className="receipt-footer">
              <p>
                Use it as <code>Authorization: Bearer &lt;key&gt;</code>.
              </p>
              <Button
                variant="ghost"
                size="sm"
                onPress={() => {
                  setCreated(undefined);
                  setCopied(false);
                }}
              >
                I’ve saved this key
              </Button>
            </div>
          </section>
        )}

        <section className="key-section" aria-label="API key list">
          <div className="list-toolbar">
            <div className="list-title">
              <h2>Your keys</h2>
              {catalog && (
                <span>
                  {active} active · {keys.length - active} revoked
                </span>
              )}
            </div>
            <div className="list-tools">
              <TextField
                value={search}
                onChange={setSearch}
                aria-label="Search keys"
                className="search-field"
              >
                <Search size={16} aria-hidden="true" />
                <Input placeholder="Search keys" />
              </TextField>
              <Button
                variant="ghost"
                size="sm"
                isIconOnly
                aria-label="Refresh keys"
                onPress={refresh}
                isDisabled={loading || busy}
              >
                <RefreshCw size={17} className={loading ? "spin" : ""} />
              </Button>
            </div>
          </div>
          {loading && !catalog ? (
            <div className="empty-state" role="status">
              <RefreshCw size={24} className="spin" aria-hidden="true" />
              <h3>Loading your keys</h3>
              <p>Connecting to the local server.</p>
            </div>
          ) : !catalog ? (
            <div className="empty-state">
              <h3>The server is unavailable</h3>
              <p>Start omni-mlx and retry the connection.</p>
            </div>
          ) : keys.length === 0 ? (
            <div className="empty-state">
              <div className="empty-icon">
                <KeyRound size={28} aria-hidden="true" />
              </div>
              <h3>Your first connection starts here</h3>
              <p>
                Create a key for each application. You can revoke its access
                whenever you need to.
              </p>
              <Button
                variant="secondary"
                onPress={() => setCreating(true)}
                isDisabled={creating}
              >
                Create your first key
              </Button>
            </div>
          ) : filtered.length === 0 ? (
            <div className="empty-state">
              <h3>No matching keys</h3>
              <p>Try another name or key prefix.</p>
              <Button variant="ghost" onPress={() => setSearch("")}>
                Clear search
              </Button>
            </div>
          ) : (
            <KeysTable
              keys={filtered}
              disabled={busy || loading}
              onRevoke={setRevoking}
            />
          )}
        </section>
        <footer className="page-footer">
          <span>
            <ShieldCheck size={16} aria-hidden="true" />
            Keys grant access to the audio API. Revocation takes effect
            immediately.
          </span>
        </footer>
        {catalog?.fixed_key_enabled && (
          <p className="fixed-key-note">
            A fixed API key is also configured through the server’s environment.
            Rotate or remove that key in the server configuration.
          </p>
        )}
      </main>
      <AlertDialog
        isOpen={!!revoking}
        onOpenChange={(open) => {
          if (!open && !busy) setRevoking(undefined);
        }}
      >
        <AlertDialog.Backdrop>
          <AlertDialog.Container>
            <AlertDialog.Dialog>
              <AlertDialog.Header>
                <AlertDialog.Heading>
                  Revoke “{revoking?.name}”?
                </AlertDialog.Heading>
              </AlertDialog.Header>
              <AlertDialog.Body>
                This application will lose access immediately. Revoked keys
                cannot be restored; create a new key to reconnect it.
              </AlertDialog.Body>
              <AlertDialog.Footer>
                <Button
                  variant="secondary"
                  onPress={() => setRevoking(undefined)}
                  isDisabled={busy}
                >
                  Keep key
                </Button>
                <Button variant="danger" onPress={revoke} isPending={busy}>
                  Revoke key
                </Button>
              </AlertDialog.Footer>
            </AlertDialog.Dialog>
          </AlertDialog.Container>
        </AlertDialog.Backdrop>
      </AlertDialog>
    </div>
  );
}
