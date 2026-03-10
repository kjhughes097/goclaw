import { useState, useEffect, useCallback } from "react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Switch } from "@/components/ui/switch";
import { Combobox } from "@/components/ui/combobox";
import { X, Save, Check, Bell } from "lucide-react";
import { useTranslation } from "react-i18next";
import { CHANNEL_TYPES } from "@/constants/channels";
import type { TeamData, TeamAccessSettings } from "@/types/team";
import { useTeams } from "./hooks/use-teams";

interface TeamSettingsTabProps {
  teamId: string;
  team: TeamData;
  onSaved: () => void;
}

function MultiSelect({
  options,
  selected,
  onChange,
  placeholder,
}: {
  options: { value: string; label?: string }[];
  selected: string[];
  onChange: (values: string[]) => void;
  placeholder: string;
}) {
  return (
    <div className="space-y-2">
      <Combobox
        value=""
        onChange={(val) => {
          if (val && !selected.includes(val)) {
            onChange([...selected, val]);
          }
        }}
        options={options.filter((o) => !selected.includes(o.value))}
        placeholder={placeholder}
      />
      {selected.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {selected.map((id) => (
            <Badge key={id} variant="secondary" className="gap-1 pr-1">
              {options.find((o) => o.value === id)?.label ?? id}
              <button
                type="button"
                onClick={() => onChange(selected.filter((s) => s !== id))}
                className="ml-0.5 rounded-full p-0.5 hover:bg-muted"
              >
                <X className="h-3 w-3" />
              </button>
            </Badge>
          ))}
        </div>
      )}
    </div>
  );
}

export function TeamSettingsTab({ teamId, team, onSaved }: TeamSettingsTabProps) {
  const { t } = useTranslation("teams");
  const { updateTeamSettings, getKnownUsers } = useTeams();
  const [knownUsers, setKnownUsers] = useState<string[]>([]);

  // Parse initial settings
  const initial = (team.settings ?? {}) as TeamAccessSettings;
  const [allowUserIds, setAllowUserIds] = useState<string[]>(initial.allow_user_ids ?? []);
  const [denyUserIds, setDenyUserIds] = useState<string[]>(initial.deny_user_ids ?? []);
  const [allowChannels, setAllowChannels] = useState<string[]>(initial.allow_channels ?? []);
  const [denyChannels, setDenyChannels] = useState<string[]>(initial.deny_channels ?? []);
  const [progressNotifications, setProgressNotifications] = useState(initial.progress_notifications ?? false);

  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Load known users for combobox
  useEffect(() => {
    getKnownUsers(teamId).then(setKnownUsers).catch(() => {});
  }, [teamId, getKnownUsers]);

  // Reset when team changes
  useEffect(() => {
    const s = (team.settings ?? {}) as TeamAccessSettings;
    setAllowUserIds(s.allow_user_ids ?? []);
    setDenyUserIds(s.deny_user_ids ?? []);
    setAllowChannels(s.allow_channels ?? []);
    setDenyChannels(s.deny_channels ?? []);
    setProgressNotifications(s.progress_notifications ?? false);
    setSaved(false);
    setError(null);
  }, [team]);

  const handleSave = useCallback(async () => {
    setSaving(true);
    setError(null);
    setSaved(false);
    try {
      const settings: TeamAccessSettings = {};
      if (allowUserIds.length > 0) settings.allow_user_ids = allowUserIds;
      if (denyUserIds.length > 0) settings.deny_user_ids = denyUserIds;
      if (allowChannels.length > 0) settings.allow_channels = allowChannels;
      if (denyChannels.length > 0) settings.deny_channels = denyChannels;
      if (progressNotifications) settings.progress_notifications = true;
      await updateTeamSettings(teamId, settings);
      setSaved(true);
      onSaved();
      setTimeout(() => setSaved(false), 3000);
    } catch (err) {
      setError(err instanceof Error ? err.message : t("settings.failedSave"));
    } finally {
      setSaving(false);
    }
  }, [teamId, allowUserIds, denyUserIds, allowChannels, denyChannels, progressNotifications, updateTeamSettings, onSaved, t]);

  const userOptions = knownUsers.map((u) => ({ value: u, label: u }));
  const channelOptions = CHANNEL_TYPES.map((c) => ({ value: c.value, label: c.label }));

  return (
    <div className="space-y-6">
      {/* User Access Control */}
      <div className="space-y-4">
        <h3 className="text-sm font-medium">{t("settings.userAccessControl")}</h3>
        <div className="space-y-3 rounded-lg border p-4">
          <div className="space-y-1.5">
            <label className="text-sm font-medium">{t("settings.allowedUsers")}</label>
            <p className="text-xs text-muted-foreground">
              {t("settings.allowedUsersHint")}
            </p>
            <MultiSelect
              options={userOptions}
              selected={allowUserIds}
              onChange={setAllowUserIds}
              placeholder={t("settings.searchUsers")}
            />
          </div>
          <div className="space-y-1.5">
            <label className="text-sm font-medium">{t("settings.deniedUsers")}</label>
            <p className="text-xs text-muted-foreground">
              {t("settings.deniedUsersHint")}
            </p>
            <MultiSelect
              options={userOptions}
              selected={denyUserIds}
              onChange={setDenyUserIds}
              placeholder={t("settings.searchUsers")}
            />
          </div>
        </div>
      </div>

      {/* Channel Restrictions */}
      <div className="space-y-4">
        <h3 className="text-sm font-medium">{t("settings.channelRestrictions")}</h3>
        <div className="space-y-3 rounded-lg border p-4">
          <div className="space-y-1.5">
            <label className="text-sm font-medium">{t("settings.allowedChannels")}</label>
            <p className="text-xs text-muted-foreground">
              {t("settings.allowedChannelsHint")}
            </p>
            <MultiSelect
              options={channelOptions}
              selected={allowChannels}
              onChange={setAllowChannels}
              placeholder={t("settings.selectChannel")}
            />
          </div>
          <div className="space-y-1.5">
            <label className="text-sm font-medium">{t("settings.deniedChannels")}</label>
            <p className="text-xs text-muted-foreground">
              {t("settings.deniedChannelsHint")}
            </p>
            <MultiSelect
              options={channelOptions}
              selected={denyChannels}
              onChange={setDenyChannels}
              placeholder={t("settings.selectChannel")}
            />
          </div>
        </div>
      </div>

      {/* Notifications */}
      <div className="space-y-4">
        <h3 className="text-sm font-medium">{t("settings.notifications")}</h3>
        <div className="rounded-lg border bg-gradient-to-r from-blue-500/5 to-purple-500/5 p-4">
          <div className="flex items-start gap-4">
            <div className="rounded-lg bg-blue-500/10 p-2.5 text-blue-600 dark:text-blue-400">
              <Bell className="h-5 w-5" />
            </div>
            <div className="flex-1 space-y-1">
              <div className="flex items-center justify-between">
                <span className="text-sm font-semibold">{t("settings.progressNotifications")}</span>
                <Switch
                  checked={progressNotifications}
                  onCheckedChange={setProgressNotifications}
                />
              </div>
              <p className="text-xs text-muted-foreground leading-relaxed">
                {t("settings.progressNotificationsHint")}
              </p>
            </div>
          </div>
        </div>
      </div>

      {/* Save button */}
      <div className="flex items-center gap-3">
        <Button onClick={handleSave} disabled={saving} className="gap-2">
          {saving ? (
            t("settings.saving")
          ) : saved ? (
            <>
              <Check className="h-4 w-4" /> {t("settings.saved")}
            </>
          ) : (
            <>
              <Save className="h-4 w-4" /> {t("settings.save")}
            </>
          )}
        </Button>
        {error && <span className="text-sm text-destructive">{error}</span>}
      </div>
    </div>
  );
}
