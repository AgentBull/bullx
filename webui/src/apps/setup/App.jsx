import React from "react"
import { useTranslation } from "react-i18next"
import {
  RiAddLine,
  RiArrowDownSLine,
  RiArrowLeftLine,
  RiArrowRightSLine,
  RiCheckboxCircleLine,
  RiCloseLine,
  RiDeleteBinLine,
  RiEditLine,
  RiExternalLinkLine,
  RiPlugLine,
  RiSaveLine,
} from "@remixicon/react"
import { Badge } from "@/uikit/components/badge"
import {
  Card,
  CardContent,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/uikit/components/card"
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "@/uikit/components/collapsible"
import { Button } from "@/uikit/components/button"
import { Input } from "@/uikit/components/input"
import { Label } from "@/uikit/components/label"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
} from "@/uikit/components/select"
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
} from "@/uikit/components/sheet"
import { Switch } from "@/uikit/components/switch"
import SetupLayout from "./Layout"

const SECRET_FIELDS = ["app_secret"]

const FALLBACK_ENTRY = {
  id: "feishu:",
  adapter: "feishu",
  channel_id: "",
  enabled: true,
  domain: "feishu",
  authn: {
    external_org_members: {
      enabled: false,
      tenant_key: "",
    },
  },
  credentials: {
    app_id: "",
    app_secret: "",
  },
  advanced: {
    dedupe_ttl_ms: 300000,
    message_context_ttl_ms: 2592000000,
    card_action_dedupe_ttl_ms: 900000,
    inline_media_max_bytes: 524288,
    stream_update_interval_ms: 100,
    state_max_age_seconds: 600,
  },
  secret_status: {
    app_secret: "missing",
  },
}

export default function SetupApp({
  app_name,
  adapter_catalog = [],
  adapters = [],
  check_path,
  save_path,
  back_path,
}) {
  const { t } = useTranslation()
  const [entries, setEntries] = React.useState(() => normalizeEntries(adapters))
  const [checks, setChecks] = React.useState({})
  const [serverErrors, setServerErrors] = React.useState([])
  const [checkingId, setCheckingId] = React.useState(null)
  const [saving, setSaving] = React.useState(false)
  const [sheetOpen, setSheetOpen] = React.useState(false)
  const [editingIndex, setEditingIndex] = React.useState(null)
  const [draft, setDraft] = React.useState(() => newEntry(adapter_catalog))
  const [draftErrors, setDraftErrors] = React.useState([])

  const listErrors = React.useMemo(() => validateEntries(entries, t), [entries, t])
  const enabledEntries = entries.filter(entry => entry.enabled !== false)
  const allEnabledChecked = enabledEntries.every(
    entry => checks[entry.id]?.status === "success",
  )
  const canSave =
    enabledEntries.length > 0
    && listErrors.length === 0
    && allEnabledChecked
    && !saving

  const clearChecks = React.useCallback((ids) => {
    const idList = Array.isArray(ids) ? ids : [ids]

    setChecks(current => {
      const next = { ...current }
      for (const id of idList) delete next[id]
      return next
    })
  }, [])

  const openNewSheet = () => {
    setEditingIndex(null)
    setDraft(newEntry(adapter_catalog))
    setDraftErrors([])
    setSheetOpen(true)
  }

  const openEditSheet = (index) => {
    setEditingIndex(index)
    setDraft(clone(entries[index]))
    setDraftErrors([])
    setSheetOpen(true)
  }

  const applyDraft = () => {
    const prepared = prepareEntryForSave(draft)
    const errors = validateDraft(prepared, entries, editingIndex, t)

    if (errors.length > 0) {
      setDraftErrors(errors)
      return
    }

    const previousId = editingIndex === null ? null : entries[editingIndex]?.id

    setEntries(current => {
      if (editingIndex === null) return [...current, prepared]

      return current.map((entry, index) => (
        index === editingIndex ? prepared : entry
      ))
    })

    clearChecks([previousId, prepared.id].filter(Boolean))
    setServerErrors([])
    setSheetOpen(false)
  }

  const removeEntry = (index) => {
    const entry = entries[index]

    setEntries(current => current.filter((_item, itemIndex) => itemIndex !== index))
    clearChecks(entry.id)
    setServerErrors([])
  }

  const runCheck = async (entry) => {
    const prepared = prepareEntryForSave(entry)
    const errors = validateEntry(prepared, t)

    if (errors.length > 0) {
      setServerErrors(errors)
      return
    }

    setCheckingId(prepared.id)
    setServerErrors([])

    const response = await postJson(check_path, { adapter: prepared })

    setCheckingId(null)

    if (response.redirect_to) {
      window.location.assign(response.redirect_to)
      return
    }

    if (!response.ok) {
      setChecks(current => ({
        ...current,
        [prepared.id]: { status: "error", errors: response.errors || [] },
      }))
      setServerErrors(response.errors || [])
      return
    }

    setChecks(current => ({
      ...current,
      [prepared.id]: {
        status: "success",
        token: response.connectivity_token,
        result: response.result,
      },
    }))
  }

  const saveAdapters = async () => {
    if (!canSave) return

    setSaving(true)
    setServerErrors([])

    const preparedEntries = entries.map(prepareEntryForSave)
    const response = await postJson(save_path, {
      adapters: preparedEntries,
      connectivity_tokens: Object.fromEntries(
        preparedEntries
          .map(entry => [entry.id, checks[entry.id]])
          .filter(([_id, check]) => check?.status === "success")
          .map(([id, check]) => [id, check.token]),
      ),
    })

    setSaving(false)

    if (response.redirect_to) {
      window.location.assign(response.redirect_to)
      return
    }

    if (!response.ok) {
      setServerErrors(response.errors || [])
    }
  }

  return (
    <SetupLayout title={t("web.setup.title")} appName={app_name}>
      <section className="grid flex-1 place-items-center py-8 sm:py-10">
        <Card size="sm" className="w-full max-w-4xl gap-0 bg-card py-0">
          <CardHeader className="border-b border-border px-5 py-4 sm:px-6">
            <div className="min-w-0">
              <p className="text-xs font-medium text-primary">
                {t("web.setup.gateway.step")}
              </p>
              <CardTitle className="mt-1 text-xl font-semibold">
                {t("web.setup.gateway.heading")}
              </CardTitle>
            </div>
          </CardHeader>

          <CardContent className="px-5 py-5 sm:px-6">
            <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div className="min-w-0">
                <p className="mt-1 text-sm text-muted-foreground">
                  {t("web.setup.gateway.description")}
                </p>
              </div>
              {entries.length > 0 ? (
                <Button type="button" onClick={openNewSheet}>
                  <RiAddLine data-icon="inline-start" />
                  <span>{t("web.setup.gateway.add_adapter")}</span>
                </Button>
              ) : null}
            </div>

            <ErrorList errors={[...listErrors, ...serverErrors]} />

            {entries.length === 0 ? (
              <EmptyState onAdd={openNewSheet} />
            ) : (
              <div className="grid gap-3">
                {entries.map((entry, index) => (
                  <AdapterRow
                    key={entry.id}
                    entry={entry}
                    catalog={adapter_catalog}
                    check={checks[entry.id]}
                    checking={checkingId === entry.id}
                    onCheck={() => runCheck(entry)}
                    onEdit={() => openEditSheet(index)}
                    onRemove={() => removeEntry(index)}
                  />
                ))}
              </div>
            )}
          </CardContent>

          <CardFooter className="flex-col items-stretch justify-between gap-3 border-t border-border px-5 py-4 sm:flex-row sm:items-center sm:px-6">
            <Button
              type="button"
              variant="ghost"
              onClick={() => window.location.assign(back_path)}
            >
              <RiArrowLeftLine data-icon="inline-start" />
              <span>{t("web.setup.gateway.actions.back_to_llm")}</span>
            </Button>
            <Button type="button" onClick={saveAdapters} disabled={!canSave}>
              <RiSaveLine data-icon="inline-start" />
              <span>
                {saving ? t("web.setup.gateway.saving") : t("web.setup.gateway.save")}
              </span>
            </Button>
          </CardFooter>
        </Card>
      </section>

      <AdapterSheet
        open={sheetOpen}
        onOpenChange={setSheetOpen}
        draft={draft}
        setDraft={(next) => {
          setDraft(next)
          setDraftErrors([])
        }}
        errors={draftErrors}
        catalog={adapter_catalog}
        entries={entries}
        editing={editingIndex !== null}
        onApply={applyDraft}
      />
    </SetupLayout>
  )
}

function AdapterRow({
  entry,
  catalog,
  check,
  checking,
  onCheck,
  onEdit,
  onRemove,
}) {
  const { t } = useTranslation()
  const prepared = prepareEntryForSave(entry)
  const invalid = prepared.enabled && validateEntry(prepared, t).length > 0
  const connected = check?.status === "success"
  const tenantPolicy = prepared.authn.external_org_members
  const metadata = [
    prepared.channel_id || t("web.setup.gateway.fields.channel_id"),
    domainLabel(prepared.domain),
    tenantPolicy.enabled && tenantPolicy.tenant_key
      ? t("web.setup.gateway.authorization.tenant_key_summary", {
        values: { tenant_key: tenantPolicy.tenant_key },
      })
      : null,
  ].filter(Boolean)

  return (
    <div className="grid gap-4 border border-border bg-background-secondary p-4 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
      <div className="min-w-0">
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <p className="min-w-0 truncate text-sm font-medium">
            {adapterLabel(prepared.adapter, catalog)}
          </p>
          <Badge variant="outline">{transportLabel(prepared.adapter)}</Badge>
        </div>
        <p className="mt-2 truncate text-xs leading-5 text-muted-foreground">
          {metadata.join(" · ")}
        </p>
      </div>

      <div className="flex flex-wrap items-center justify-start gap-2 sm:justify-end">
        <ConnectionBadge
          disabled={!prepared.enabled}
          invalid={invalid}
          checking={checking}
          connected={connected}
          error={check?.status === "error"}
        />
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={!prepared.enabled || invalid || checking}
          onClick={onCheck}
        >
          <RiPlugLine data-icon="inline-start" />
          <span>{t("web.setup.gateway.actions.check")}</span>
        </Button>
        <Button
          type="button"
          size="icon-sm"
          variant="ghost"
          aria-label={t("web.setup.gateway.actions.edit")}
          onClick={onEdit}
        >
          <RiEditLine />
        </Button>
        <Button
          type="button"
          size="icon-sm"
          variant="ghost"
          aria-label={t("web.setup.gateway.actions.remove")}
          onClick={onRemove}
        >
          <RiDeleteBinLine />
        </Button>
      </div>
    </div>
  )
}

function EmptyState({ onAdd }) {
  const { t } = useTranslation()

  return (
    <div className="grid min-h-48 place-items-center border border-border bg-background-secondary px-4 py-10 text-center">
      <div className="grid justify-items-center gap-4">
        <div>
          <p className="text-base font-medium">{t("web.setup.gateway.empty_title")}</p>
          <p className="mt-2 text-sm text-muted-foreground">
            {t("web.setup.gateway.empty_description")}
          </p>
        </div>
        <Button type="button" onClick={onAdd}>
          <RiAddLine data-icon="inline-start" />
          <span>{t("web.setup.gateway.add_adapter")}</span>
        </Button>
      </div>
    </div>
  )
}

function AdapterSheet({
  open,
  onOpenChange,
  draft,
  setDraft,
  errors,
  catalog,
  entries,
  editing,
  onApply,
}) {
  const { t } = useTranslation()
  const [mode, setMode] = React.useState(editing ? "configure" : "select")
  const [advancedOpen, setAdvancedOpen] = React.useState(false)
  const advancedContentRef = React.useRef(null)
  const catalogOptions = catalog.length
    ? catalog
    : [{
      adapter: "feishu",
      label: "Feishu / Lark",
      default_entry: FALLBACK_ENTRY,
      authn_policies: [{ type: "external_org_members" }],
    }]
  const docUrl = configDocUrl(draft, catalogOptions)
  const supportsExternalOrgMembers = connectorSupportsAuthnPolicy(
    draft.adapter,
    catalogOptions,
    "external_org_members",
  )
  const fieldErrors = React.useMemo(() => errorsByField(errors), [errors])
  const formErrors = React.useMemo(() => errorsWithoutFields(errors), [errors])

  React.useEffect(() => {
    if (!open) return

    setAdvancedOpen(false)
    setMode(editing ? "configure" : "select")
  }, [editing, open])

  React.useEffect(() => {
    if (!advancedOpen) return

    requestAnimationFrame(() => {
      advancedContentRef.current?.scrollIntoView({ block: "nearest" })
    })
  }, [advancedOpen])

  const update = (path, value) => {
    setDraft(setPath(draft, path, value))
  }

  const chooseAdapter = (catalogEntry) => {
    const adapter = catalogEntry.adapter
    const next = mergeEntry({
      ...(catalogEntry?.default_entry || {}),
      adapter,
      id: nextEntryId(adapter),
      channel_id: nextDefaultChannelId(adapter, entries),
    })

    setDraft(next)
    setMode("configure")
  }

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        className={[
          "top-1/2! right-1/2! bottom-auto! left-auto! max-w-none! translate-x-1/2! -translate-y-1/2! overflow-hidden border border-border",
          mode === "select"
            ? "h-auto! max-h-[min(42rem,calc(100vh-2rem))]! w-[min(48rem,calc(100vw-2rem))]!"
            : "h-[min(42rem,calc(100vh-2rem))]! w-[min(56rem,calc(100vw-2rem))]!",
        ].join(" ")}
        showCloseButton={false}
      >
        <SheetHeader className="shrink-0 border-b border-border px-5 py-5 sm:px-6">
          <div className="flex items-start justify-between gap-4">
            <div className="min-w-0">
              <SheetTitle>
                {mode === "select"
                  ? t("web.setup.gateway.sheet.select_title")
                  : editing
                  ? t("web.setup.gateway.sheet.edit_title")
                  : t("web.setup.gateway.sheet.add_title")}
              </SheetTitle>
              <SheetDescription>
                {mode == "select" ? (
                 ''
                ) : (
                  <>
                    {adapterLabel(draft.adapter, catalogOptions)}
                    {" · "}
                    {transportLabel(draft.adapter)}
                  </>
                )}
              </SheetDescription>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              {mode === "configure" && docUrl ? (
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  onClick={() => window.open(docUrl, "_blank", "noopener,noreferrer")}
                >
                  <RiExternalLinkLine data-icon="inline-start" />
                  <span>{t("web.setup.gateway.docs")}</span>
                </Button>
              ) : null}
              <Button
                type="button"
                size="icon-sm"
                variant="ghost"
                aria-label={t("app.close")}
                onClick={() => onOpenChange(false)}
              >
                <RiCloseLine />
              </Button>
            </div>
          </div>
        </SheetHeader>

        <div className="grid min-h-0 flex-1 gap-5 overflow-y-auto px-5 py-5 sm:px-6">
          {mode === "select" ? (
            <AdapterTypeChooser catalog={catalogOptions} onChoose={chooseAdapter} />
          ) : (
            <>
              <ErrorList errors={formErrors} />

              <FormSection title={t("web.setup.gateway.sections.channel")}>
                <div className="grid gap-4 sm:grid-cols-2">
                  <Field
                    label={t("web.setup.gateway.fields.channel_id")}
                    required
                    error={fieldErrors.channel_id}
                  >
                    <Input
                      value={draft.channel_id}
                      onChange={event => update(["channel_id"], event.target.value)}
                      autoComplete="off"
                      aria-invalid={Boolean(fieldErrors.channel_id) || undefined}
                      autoFocus
                      required
                    />
                  </Field>

                  <Field label={t("web.setup.gateway.fields.domain")}>
                    <Select
                      value={draft.domain}
                      onValueChange={value => update(["domain"], value)}
                    >
                      <SelectTrigger className="w-full">
                        <span data-slot="select-value">{domainLabel(draft.domain)}</span>
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="feishu">Feishu</SelectItem>
                        <SelectItem value="lark">Lark</SelectItem>
                      </SelectContent>
                    </Select>
                  </Field>
                </div>
              </FormSection>

              {supportsExternalOrgMembers ? (
                <FormSection title={t("web.setup.gateway.sections.authorization")}>
                  <div className="grid gap-4">
                    <div className="flex items-start justify-between gap-4 border border-border bg-background-secondary p-4">
                      <div className="min-w-0">
                        <p className="text-sm font-medium">
                          {t("web.setup.gateway.authorization.external_org_members")}
                        </p>
                        <p className="mt-1 text-sm leading-5 text-muted-foreground">
                          {t("web.setup.gateway.authorization.external_org_members_description")}
                        </p>
                      </div>
                      <Switch
                        checked={Boolean(draft.authn.external_org_members.enabled)}
                        onCheckedChange={checked => update(
                          ["authn", "external_org_members", "enabled"],
                          checked,
                        )}
                        aria-label={t("web.setup.gateway.authorization.external_org_members")}
                      />
                    </div>

                    {draft.authn.external_org_members.enabled ? (
                      <Field
                        label={t("web.setup.gateway.fields.tenant_key")}
                        required
                        error={fieldErrors["authn.external_org_members.tenant_key"]}
                      >
                        <Input
                          value={draft.authn.external_org_members.tenant_key}
                          onChange={event => update(
                            ["authn", "external_org_members", "tenant_key"],
                            event.target.value,
                          )}
                          autoComplete="off"
                          aria-invalid={
                            Boolean(fieldErrors["authn.external_org_members.tenant_key"])
                            || undefined
                          }
                          required
                        />
                      </Field>
                    ) : null}
                  </div>
                </FormSection>
              ) : null}

              <FormSection title={t("web.setup.gateway.sections.credentials")}>
                <div className="grid gap-4 sm:grid-cols-2">
                  <Field
                    label={t("web.setup.gateway.fields.app_id")}
                    required
                    error={fieldErrors["credentials.app_id"]}
                  >
                    <Input
                      value={draft.credentials.app_id}
                      onChange={event => update(["credentials", "app_id"], event.target.value)}
                      autoComplete="off"
                      aria-invalid={Boolean(fieldErrors["credentials.app_id"]) || undefined}
                      required
                    />
                  </Field>
                  <SecretField
                    label={t("web.setup.gateway.fields.app_secret")}
                    value={draft.credentials.app_secret}
                    status={draft.secret_status?.app_secret}
                    onChange={value => update(["credentials", "app_secret"], value)}
                    required
                    error={fieldErrors["credentials.app_secret"]}
                  />
                </div>
              </FormSection>

              <Collapsible open={advancedOpen} onOpenChange={setAdvancedOpen}>
                <FormSection
                  title={
                    <CollapsibleTrigger className="flex w-full cursor-pointer items-center justify-between gap-3 text-left">
                      <span>{t("web.setup.gateway.sections.advanced")}</span>
                      <RiArrowDownSLine
                        className={[
                          "size-4 shrink-0 text-muted-foreground transition-transform",
                          advancedOpen ? "rotate-180" : "",
                        ].join(" ")}
                      />
                    </CollapsibleTrigger>
                  }
                >
                  <CollapsibleContent>
                    <div ref={advancedContentRef} className="grid gap-4 pt-1 md:grid-cols-3">
                      {[
                        "dedupe_ttl_ms",
                        "message_context_ttl_ms",
                        "card_action_dedupe_ttl_ms",
                        "inline_media_max_bytes",
                        "stream_update_interval_ms",
                        "state_max_age_seconds",
                      ].map(field => (
                        <Field key={field} label={t(`web.setup.gateway.fields.${field}`)}>
                          <Input
                            type="number"
                            min="0"
                            value={draft.advanced[field]}
                            onChange={event => update(["advanced", field], numberValue(event.target.value))}
                          />
                        </Field>
                      ))}
                    </div>
                  </CollapsibleContent>
                </FormSection>
              </Collapsible>
            </>
          )}
        </div>

        {mode === "configure" ? (
          <SheetFooter className="shrink-0">
            <Button type="button" variant="ghost" onClick={() => onOpenChange(false)}>
              {t("web.setup.gateway.sheet.cancel")}
            </Button>
            <Button type="button" onClick={onApply}>
              {editing ? (
                <RiSaveLine data-icon="inline-start" />
              ) : (
                <RiAddLine data-icon="inline-start" />
              )}
              <span>
                {editing
                  ? t("web.setup.gateway.sheet.save_changes")
                  : t("web.setup.gateway.add_adapter")}
              </span>
            </Button>
          </SheetFooter>
        ) : null}
      </SheetContent>
    </Sheet>
  )
}

function AdapterTypeChooser({ catalog, onChoose }) {
  return (
    <div
      className={[
        "grid self-start gap-3",
        catalog.length > 1 ? "sm:grid-cols-2" : "sm:grid-cols-[minmax(0,24rem)]",
      ].join(" ")}
    >
      {catalog.map(item => (
        <button
          key={item.adapter}
          type="button"
          className="group grid min-h-28 gap-4 border border-border bg-background-secondary p-4 text-left transition-colors hover:border-primary hover:bg-muted focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/30 focus-visible:outline-none"
          onClick={() => onChoose(item)}
        >
          <span className="flex items-center justify-between gap-4">
            <span className="min-w-0 truncate text-base font-semibold">
              {item.label || adapterLabel(item.adapter, catalog)}
            </span>
            <RiArrowRightSLine className="size-5 shrink-0 text-muted-foreground group-hover:text-primary" />
          </span>
          <span className="flex flex-wrap gap-2">
            <Badge variant="outline">{transportLabel(item.adapter)}</Badge>
          </span>
        </button>
      ))}
    </div>
  )
}

function FormSection({ title, children }) {
  return (
    <section className="grid gap-3">
      <h3 className="border-b border-border pb-2 text-sm font-semibold">{title}</h3>
      {children}
    </section>
  )
}

function Field({ label, children, required = false, error }) {
  const { t } = useTranslation()

  return (
    <div className="grid gap-1.5">
      <Label className="items-baseline">
        <span>{label}</span>
        {required ? (
          <span className="text-muted-foreground">
            {t("web.setup.gateway.required")}
          </span>
        ) : null}
      </Label>
      {children}
      {error ? (
        <p className="text-xs leading-4 text-destructive">{error}</p>
      ) : null}
    </div>
  )
}

function SecretField({ label, value, status, onChange, required = false, error }) {
  const { t } = useTranslation()

  return (
    <Field label={label} required={required} error={error}>
      <div className="grid gap-2">
        <Input
          type="password"
          value={value}
          placeholder={status === "stored" ? t("web.setup.gateway.secret_stored") : ""}
          onChange={event => onChange(event.target.value)}
          autoComplete="new-password"
          aria-invalid={Boolean(error) || undefined}
          required={required}
        />
        {status === "stored" ? (
          <Badge variant="secondary" className="w-fit">
            {t("web.setup.gateway.secret_stored_badge")}
          </Badge>
        ) : null}
      </div>
    </Field>
  )
}

function ConnectionBadge({ disabled, invalid, checking, connected, error }) {
  const { t } = useTranslation()

  if (disabled) {
    return <Badge variant="secondary">{t("web.setup.gateway.status.disabled")}</Badge>
  }

  if (invalid) {
    return <Badge variant="destructive">{t("web.setup.gateway.status.invalid")}</Badge>
  }

  if (checking) {
    return <Badge variant="secondary">{t("web.setup.gateway.status.checking")}</Badge>
  }

  if (connected) {
    return (
      <Badge>
        <RiCheckboxCircleLine />
        <span>{t("web.setup.gateway.status.connected")}</span>
      </Badge>
    )
  }

  if (error) {
    return <Badge variant="destructive">{t("web.setup.gateway.status.failed")}</Badge>
  }

  return <Badge variant="outline">{t("web.setup.gateway.status.unchecked")}</Badge>
}

function ErrorList({ errors }) {
  if (!errors.length) return null

  return (
    <div className="border-l-4 border-destructive bg-destructive/10 px-4 py-3 text-sm text-destructive">
      {errors.map((error, index) => (
        <p key={`${error.message}-${index}`}>{error.message}</p>
      ))}
    </div>
  )
}

async function postJson(path, payload) {
  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

  try {
    const response = await fetch(path, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": csrfToken || "",
      },
      body: JSON.stringify(payload),
    })

    return await response.json()
  } catch (error) {
    return {
      ok: false,
      errors: [{ message: error.message || String(error) }],
    }
  }
}

function normalizeEntries(entries) {
  return entries.map(entry => mergeEntry(entry))
}

function newEntry(catalog) {
  const catalogEntry = catalogEntryFor(catalog, "feishu") || catalog[0]
  const adapter = catalogEntry?.adapter || "feishu"

  return mergeEntry({
    ...(catalogEntry?.default_entry || {}),
    adapter,
    id: nextEntryId(adapter),
    channel_id: "",
  })
}

function nextDefaultChannelId(adapter, entries) {
  const existingChannelIds = new Set(
    entries
      .map(prepareEntryForSave)
      .filter(entry => entry.adapter === adapter)
      .map(entry => entry.channel_id),
  )

  if (!existingChannelIds.has(adapter)) return adapter

  let suffix = 2
  while (existingChannelIds.has(`${adapter}-${suffix}`)) suffix += 1

  return `${adapter}-${suffix}`
}

function mergeEntry(entry) {
  const source = clone(entry || {})
  const merged = {
    ...clone(FALLBACK_ENTRY),
    ...source,
    credentials: {
      ...FALLBACK_ENTRY.credentials,
      ...(source.credentials || {}),
    },
    authn: {
      external_org_members: {
        ...FALLBACK_ENTRY.authn.external_org_members,
        ...(source.authn?.external_org_members || {}),
      },
    },
    advanced: {
      ...FALLBACK_ENTRY.advanced,
      ...(source.advanced || {}),
    },
    secret_status: {
      ...FALLBACK_ENTRY.secret_status,
      ...(source.secret_status || {}),
    },
  }

  for (const field of SECRET_FIELDS) {
    merged.credentials[field] = merged.credentials[field] || ""
  }

  return merged
}

function prepareEntryForSave(entry) {
  const normalized = mergeEntry(entry)
  const channelId = normalized.channel_id.trim()
  const adapter = normalized.adapter || "feishu"
  const id = channelId ? `${adapter}:${channelId}` : normalized.id

  return {
    id,
    adapter,
    channel_id: channelId,
    enabled: normalized.enabled !== false,
    domain: normalized.domain,
    authn: {
      external_org_members: {
        enabled: Boolean(normalized.authn.external_org_members.enabled),
        tenant_key: normalized.authn.external_org_members.tenant_key.trim(),
      },
    },
    credentials: {
      app_id: normalized.credentials.app_id.trim(),
      app_secret: normalized.credentials.app_secret.trim(),
    },
    advanced: Object.fromEntries(
      Object.entries(normalized.advanced).map(([key, value]) => [
        key,
        numberValue(value),
      ]),
    ),
    secret_status: normalized.secret_status,
  }
}

function setPath(object, path, value) {
  const next = clone(object)
  let cursor = next

  for (const key of path.slice(0, -1)) {
    cursor[key] = isPlainObject(cursor[key]) ? { ...cursor[key] } : {}
    cursor = cursor[key]
  }

  cursor[path[path.length - 1]] = value
  return next
}

function validateEntries(entries, t) {
  const errors = entries.flatMap(entry => validateEntry(prepareEntryForSave(entry), t))
  const seen = new Set()

  for (const entry of entries.map(prepareEntryForSave).filter(item => item.enabled)) {
    const key = `${entry.adapter}:${entry.channel_id}`
    if (seen.has(key)) {
      errors.push({
        field: "channel_id",
        message: t("web.setup.gateway.errors.duplicate_channel", {
          values: { channel: key },
        }),
      })
    }
    seen.add(key)
  }

  return errors
}

function validateDraft(entry, entries, editingIndex, t) {
  const errors = validateEntry(entry, t)
  const key = `${entry.adapter}:${entry.channel_id}`
  const duplicate = entries
    .map(prepareEntryForSave)
    .some((item, index) => (
      index !== editingIndex
      && item.enabled
      && item.adapter === entry.adapter
      && item.channel_id === entry.channel_id
    ))

  if (duplicate) {
    errors.push({
      field: "channel_id",
      message: t("web.setup.gateway.errors.duplicate_channel", {
        values: { channel: key },
      }),
    })
  }

  return errors
}

function validateEntry(entry, t) {
  if (!entry.enabled) return []

  const errors = []

  if (!entry.channel_id.trim()) {
    errors.push({
      field: "channel_id",
      message: t("web.setup.gateway.errors.channel_id_required"),
    })
  }

  if (!entry.credentials.app_id.trim()) {
    errors.push({
      field: "credentials.app_id",
      message: t("web.setup.gateway.errors.app_id_required"),
    })
  }

  if (!hasSecret(entry, "app_secret")) {
    errors.push({
      field: "credentials.app_secret",
      message: t("web.setup.gateway.errors.app_secret_required"),
    })
  }

  if (
    entry.authn.external_org_members.enabled
    && !entry.authn.external_org_members.tenant_key.trim()
  ) {
    errors.push({
      field: "authn.external_org_members.tenant_key",
      message: t("web.setup.gateway.errors.tenant_key_required"),
    })
  }

  return errors
}

function errorsByField(errors) {
  return errors.reduce((fields, error) => {
    const field = errorField(error)
    if (field && !fields[field]) fields[field] = error.message
    return fields
  }, {})
}

function errorsWithoutFields(errors) {
  return errors.filter(error => !errorField(error))
}

function errorField(error) {
  return error.field || error.details?.field || error.details?.field_path
}

function hasSecret(entry, field) {
  return Boolean(entry.credentials[field]?.trim() || entry.secret_status?.[field] === "stored")
}

function numberValue(value) {
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0
}

function nextEntryId(adapter) {
  if (globalThis.crypto?.randomUUID) return `${adapter}:${globalThis.crypto.randomUUID()}`

  return `${adapter}:${Date.now()}:${Math.random().toString(36).slice(2)}`
}

function catalogEntryFor(catalog, adapter) {
  return catalog.find(item => item.adapter === adapter)
}

function configDocUrl(entry, catalog) {
  return catalogEntryFor(catalog, entry.adapter)?.config_doc_url || entry.config_doc_url
}

function connectorSupportsAuthnPolicy(adapter, catalog, policyType) {
  const policies = catalogEntryFor(catalog, adapter)?.authn_policies || []

  return policies.some(policy => policy.type === policyType)
}

function adapterLabel(adapter, catalog = []) {
  return catalogEntryFor(catalog, adapter)?.label || (adapter === "feishu" ? "Feishu / Lark" : adapter)
}

function transportLabel(_adapter) {
  return "WebSocket"
}

function domainLabel(domain) {
  if (domain === "lark") return "Lark"
  return "Feishu"
}

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}
