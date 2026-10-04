import { Button } from "@heroui/react/button";
import { KeyRound, Trash2 } from "lucide-react";
import type { APIKey } from "./api";

const date = (seconds: number) =>
  new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(
    seconds * 1000,
  );

type Props = {
  keys: readonly APIKey[];
  disabled: boolean;
  onRevoke: (key: APIKey) => void;
};

export function KeysTable({ keys, disabled, onRevoke }: Props) {
  return (
    <div
      className="table-scroll"
      tabIndex={0}
      role="region"
      aria-label="API key details"
    >
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Key</th>
            <th>Created</th>
            <th>Status</th>
            <th>
              <span className="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody>
          {keys.map((key) => {
            const revoked = key.revoked_at !== undefined;
            return (
              <tr key={key.id} className={revoked ? "revoked-row" : ""}>
                <td className="key-name">
                  <KeyRound size={16} aria-hidden="true" />
                  <span>{key.name}</span>
                </td>
                <td>
                  <code>{key.prefix}…</code>
                </td>
                <td>
                  <time
                    dateTime={new Date(key.created_at * 1000).toISOString()}
                  >
                    {date(key.created_at)}
                  </time>
                </td>
                <td>
                  <span className={`status ${revoked ? "revoked" : "active"}`}>
                    {revoked ? "Revoked" : "Active"}
                  </span>
                </td>
                <td className="row-action">
                  {key.revoked_at === undefined ? (
                    <Button
                      variant="ghost"
                      size="sm"
                      onPress={() => onRevoke(key)}
                      isDisabled={disabled}
                      aria-label={`Revoke ${key.name}`}
                    >
                      <Trash2 size={15} aria-hidden="true" />
                      <span>Revoke</span>
                    </Button>
                  ) : (
                    <span className="revoked-date" title={date(key.revoked_at)}>
                      Access removed
                    </span>
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
