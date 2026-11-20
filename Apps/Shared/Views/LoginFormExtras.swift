import DeadboltCore
import SwiftUI

// The "More options" parts of the login form that are lists: other websites and custom fields.
// iPhone: cards with a caption. Mac: compact rows that sit in the form's grid.

#if os(iOS)
struct OtherWebsitesEditor: View {
    @Bindable var form: LoginFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OTHER WEBSITES").font(.db(12, .semibold)).tracking(0.8).foregroundStyle(DB.text3).padding(.leading, 4)
            Card {
                ForEach(Array(form.extraSites.enumerated()), id: \.offset) { i, _ in
                    HStack(spacing: 10) {
                        TextField("another-site.com", text: $form.extraSites[i]).font(.db(16)).keyboardType(.URL)
                        Button { form.extraSites.remove(at: i) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(DB.text3).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain).accessibilityLabel("Remove website")
                    }
                    .padding(.leading, 16).frame(minHeight: 52)
                    CardDivider()
                }
                Button { form.extraSites.append("") } label: {
                    Label("Add website", systemImage: "plus").font(.db(15, .semibold)).foregroundStyle(DB.brass)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(minHeight: 48)
                }
                .buttonStyle(.plain)
            }
            Text("The login is also offered on these sites (and their subdomains).").font(.db(12)).foregroundStyle(DB.text3).padding(.horizontal, 4)
        }
    }
}

struct CustomFieldsEditor: View {
    @Bindable var form: LoginFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CUSTOM FIELDS").font(.db(12, .semibold)).tracking(0.8).foregroundStyle(DB.text3).padding(.leading, 4)
            ForEach($form.customFields) { $f in
                Card {
                    TextField("Name, like Account ID", text: $f.name).font(.db(15, .semibold)).padding(.horizontal, 16).frame(minHeight: 48)
                    CardDivider()
                    Group {
                        if f.hidden { SecureField("Value", text: $f.value) } else { TextField("Value", text: $f.value) }
                    }
                    .font(.db(16)).padding(.horizontal, 16).frame(minHeight: 48)
                    CardDivider()
                    HStack {
                        Toggle("Hide the value", isOn: $f.hidden).font(.db(14)).tint(DB.brass)
                        Button(role: .destructive) { form.customFields.removeAll { $0.id == f.id } } label: {
                            Image(systemName: "trash").foregroundStyle(DB.danger).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain).accessibilityLabel("Remove field")
                    }
                    .padding(.leading, 16).frame(minHeight: 48)
                }
            }
            Button { form.customFields.append(CustomField()) } label: {
                Label("Add field", systemImage: "plus").font(.db(15, .semibold)).foregroundStyle(DB.brass)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(minHeight: 48)
                    .background(DB.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
#else
struct MacExtraWebsites: View {
    @Bindable var form: LoginFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(form.extraSites.enumerated()), id: \.offset) { i, _ in
                HStack(spacing: 6) {
                    TextField("another-site.com", text: $form.extraSites[i]).macField()
                    Button { form.extraSites.remove(at: i) } label: { Image(systemName: "minus").frame(width: 12) }
                        .buttonStyle(MacButtonStyle()).help("Remove website")
                }
            }
            Button { form.extraSites.append("") } label: { Label("Add Website", systemImage: "plus") }.buttonStyle(MacButtonStyle())
        }
    }
}

struct MacCustomFields: View {
    @Bindable var form: LoginFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($form.customFields) { $f in
                HStack(spacing: 6) {
                    TextField("Name", text: $f.name).macField().frame(width: 120)
                    Group {
                        if f.hidden { SecureField("Value", text: $f.value) } else { TextField("Value", text: $f.value) }
                    }
                    .macField()
                    Toggle("Hide", isOn: $f.hidden).toggleStyle(.checkbox).font(.db(12))
                    Button { form.customFields.removeAll { $0.id == f.id } } label: { Image(systemName: "minus").frame(width: 12) }
                        .buttonStyle(MacButtonStyle()).help("Remove field")
                }
            }
            Button { form.customFields.append(CustomField()) } label: { Label("Add Field", systemImage: "plus") }.buttonStyle(MacButtonStyle())
        }
    }
}
#endif
