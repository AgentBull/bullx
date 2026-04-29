import React from "react"
import { Head } from "@inertiajs/react"
import { useTranslation } from "react-i18next"
import { Card, CardContent } from "@/uikit/components/card"

export default function SessionsNew({ form_action }) {
  const { t } = useTranslation()

  return (
    <main className="min-h-screen bg-background px-4 py-10 text-foreground sm:px-6 lg:px-8">
      <Head title={t("web.sessions.new.title")} />

      <div className="mx-auto flex min-h-[calc(100vh-5rem)] w-full max-w-md items-center">
        <section className="w-full">
          <div className="mb-8 flex items-center gap-3">
            <img src="/images/logo.svg" className="size-10" alt="" />
            <div>
              <h1 className="text-xl font-semibold">{t("web.sessions.new.brand")}</h1>
              <p className="text-sm text-muted-foreground">{t("web.sessions.new.subtitle")}</p>
            </div>
          </div>

          <Card>
            <CardContent>
              <p className="text-sm leading-6 text-muted-foreground">
                {t("web.sessions.new.placeholder", {
                  values: { form_action },
                })}
              </p>
            </CardContent>
          </Card>
        </section>
      </div>
    </main>
  )
}
