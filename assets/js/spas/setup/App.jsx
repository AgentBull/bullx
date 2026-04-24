import React from "react"
import { Head } from "@inertiajs/react"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

export default function SetupApp({ app_name }) {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <Head title="Setup" />

      <div className="mx-auto flex min-h-screen w-full max-w-3xl items-center px-4 py-10 sm:px-6 lg:px-8">
        <Card className="w-full">
          <CardHeader>
            <CardDescription className="font-medium uppercase text-primary">{app_name}</CardDescription>
            <CardTitle className="text-3xl">Initial setup wizard</CardTitle>
            <CardDescription className="max-w-2xl leading-6">
              This SPA is available only while the Users table is empty. The first-user setup flow will live here.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="rounded-lg border border-dashed border-border bg-muted/30 p-5 text-sm text-muted-foreground">
              Setup form placeholder
            </div>
          </CardContent>
        </Card>
      </div>
    </main>
  )
}
