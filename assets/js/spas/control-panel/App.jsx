import React from "react"
import { Head } from "@inertiajs/react"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

const sections = [
  ["Sessions", "Active runtime sessions will be managed here."],
  ["Approvals", "Human-in-the-loop queues will be managed here."],
  ["Observability", "Gateway, runtime, and brain health will be shown here."],
]

export default function ControlPanelApp({ app_name, current_user, swagger_ui_path }) {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <Head title="Control Panel" />

      <div className="mx-auto flex min-h-screen w-full max-w-6xl flex-col px-4 py-6 sm:px-6 lg:px-8">
        <header className="flex items-center justify-between border-b border-border pb-4">
          <div className="flex items-center gap-3">
            <img src="/images/logo.svg" className="size-10" alt="" />
            <div>
              <p className="text-lg font-semibold leading-6">{app_name}</p>
              <p className="text-sm text-muted-foreground">Control Panel SPA</p>
            </div>
          </div>

          <div className="text-right">
            <p className="text-sm font-medium">{current_user.display_name}</p>
            <p className="text-xs text-muted-foreground">{current_user.email || current_user.id}</p>
          </div>
        </header>

        <section className="grid flex-1 content-center gap-6 py-8 lg:grid-cols-[1fr_22rem]">
          <div className="space-y-6">
            <div>
              <p className="text-sm font-medium uppercase text-primary">Authenticated</p>
              <h1 className="mt-3 max-w-3xl text-4xl font-semibold leading-tight sm:text-5xl">
                Operator console
              </h1>
            </div>

            <div className="grid gap-3 sm:grid-cols-3">
              {sections.map(([label, body]) => (
                <Card key={label}>
                  <CardHeader>
                    <CardTitle>{label}</CardTitle>
                    <CardDescription className="leading-6">{body}</CardDescription>
                  </CardHeader>
                </Card>
              ))}
            </div>
          </div>

          <Card>
            <CardHeader>
              <CardTitle className="text-sm uppercase text-muted-foreground">API</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              <Button asChild className="w-full justify-between">
                <a href="/.well-known/service-desc">
                  OpenAPI JSON
                  <span aria-hidden="true">/.well-known/service-desc</span>
                </a>
              </Button>
              {swagger_ui_path && (
                <Button asChild variant="outline" className="w-full justify-between">
                  <a href={swagger_ui_path}>
                    Swagger UI
                    <span aria-hidden="true">{swagger_ui_path}</span>
                  </a>
                </Button>
              )}
            </CardContent>
          </Card>
        </section>
      </div>
    </main>
  )
}
