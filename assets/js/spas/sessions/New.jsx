import React from "react"
import { Head } from "@inertiajs/react"
import { Card, CardContent } from "@/components/ui/card"

export default function SessionsNew({ form_action }) {
  return (
    <main className="min-h-screen bg-background px-4 py-10 text-foreground sm:px-6 lg:px-8">
      <Head title="Sign In" />

      <div className="mx-auto flex min-h-[calc(100vh-5rem)] w-full max-w-md items-center">
        <section className="w-full">
          <div className="mb-8 flex items-center gap-3">
            <img src="/images/logo.svg" className="size-10" alt="" />
            <div>
              <h1 className="text-xl font-semibold">BullX</h1>
              <p className="text-sm text-muted-foreground">Session SPA</p>
            </div>
          </div>

          <Card>
            <CardContent>
              <p className="text-sm leading-6 text-muted-foreground">
                Login screen placeholder. Auth-code submission will post to {form_action}.
              </p>
            </CardContent>
          </Card>
        </section>
      </div>
    </main>
  )
}
