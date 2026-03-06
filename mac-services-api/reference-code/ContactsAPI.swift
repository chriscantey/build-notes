import Foundation
import Contacts

// MARK: - Types

struct ContactJSON: Codable {
    let identifier: String
    let fullName: String?
    let givenName: String
    let familyName: String
    let nickname: String
    let organizationName: String
    let jobTitle: String
    let contactType: String
    let phoneNumbers: [LabeledValueJSON]
    let emailAddresses: [LabeledValueJSON]
    let postalAddresses: [PostalAddressJSON]
    let urlAddresses: [LabeledValueJSON]
    let socialProfiles: [SocialProfileJSON]
    let birthday: BirthdayJSON?
    let note: String
}

struct LabeledValueJSON: Codable { let label: String; let value: String }
struct PostalAddressJSON: Codable { let label: String; let street: String; let city: String; let state: String; let postalCode: String; let country: String }
struct SocialProfileJSON: Codable { let label: String; let service: String; let username: String }
struct BirthdayJSON: Codable { let year: Int?; let month: Int?; let day: Int? }
struct GroupJSON: Codable { let identifier: String; let name: String }

struct GroupsResponse: Codable { let groups: [GroupJSON] }
struct ContactsListResponse: Codable { let count: Int; let contacts: [ContactJSON] }
struct SingleContactResponse: Codable { let contact: ContactJSON }
struct ContactCreateResponse: Codable { let success: Bool; let identifier: String; let message: String }

// MARK: - Contact Keys

func allContactKeys() -> [CNKeyDescriptor] {
    var keys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactTypeKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,
        CNContactSocialProfilesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactNoteKey as CNKeyDescriptor,
        CNContactImageDataAvailableKey as CNKeyDescriptor,
    ]
    keys.append(CNContactFormatter.descriptorForRequiredKeys(for: .fullName))
    return keys
}

// MARK: - Serialization

func contactToJSON(_ contact: CNContact) -> ContactJSON {
    let phones = contact.phoneNumbers.map {
        LabeledValueJSON(label: labelString($0.label), value: $0.value.stringValue)
    }
    let emails = contact.emailAddresses.map {
        LabeledValueJSON(label: labelString($0.label), value: $0.value as String)
    }
    let addresses = contact.postalAddresses.map { labeled in
        let a = labeled.value
        return PostalAddressJSON(label: labelString(labeled.label),
                                 street: a.street, city: a.city, state: a.state,
                                 postalCode: a.postalCode, country: a.country)
    }
    let urls = contact.urlAddresses.map {
        LabeledValueJSON(label: labelString($0.label), value: $0.value as String)
    }
    let socials = contact.socialProfiles.map { labeled in
        let p = labeled.value
        return SocialProfileJSON(label: labelString(labeled.label), service: p.service, username: p.username)
    }
    var birthday: BirthdayJSON? = nil
    if let b = contact.birthday {
        birthday = BirthdayJSON(
            year: b.year == NSDateComponentUndefined ? nil : b.year,
            month: b.month == NSDateComponentUndefined ? nil : b.month,
            day: b.day == NSDateComponentUndefined ? nil : b.day
        )
    }

    return ContactJSON(
        identifier: contact.identifier,
        fullName: CNContactFormatter.string(from: contact, style: .fullName),
        givenName: contact.givenName,
        familyName: contact.familyName,
        nickname: contact.nickname,
        organizationName: contact.organizationName,
        jobTitle: contact.jobTitle,
        contactType: contact.contactType == .person ? "person" : "organization",
        phoneNumbers: phones, emailAddresses: emails, postalAddresses: addresses,
        urlAddresses: urls, socialProfiles: socials, birthday: birthday,
        note: contact.isKeyAvailable(CNContactNoteKey) ? contact.note : ""
    )
}

func labelString(_ label: String?) -> String {
    guard let label = label else { return "other" }
    return CNLabeledValue<NSString>.localizedString(forLabel: label)
}

// MARK: - Handlers

func handleGetGroups() -> HTTPResponse {
    do {
        let groups = try contactStore.groups(matching: nil)
        return jsonResponse(GroupsResponse(groups: groups.map { GroupJSON(identifier: $0.identifier, name: $0.name) }))
    } catch {
        return jsonError("Failed to fetch groups: \(error.localizedDescription)")
    }
}

func handleGetGroupContacts(groupId: String) -> HTTPResponse {
    do {
        let contacts = try contactStore.unifiedContacts(
            matching: CNContact.predicateForContactsInGroup(withIdentifier: groupId),
            keysToFetch: allContactKeys()
        )
        return jsonResponse(ContactsListResponse(count: contacts.count, contacts: contacts.map { contactToJSON($0) }))
    } catch {
        return jsonError("Failed to get contacts in group: \(error.localizedDescription)")
    }
}

func handleSearchContacts(req: HTTPRequest) -> HTTPResponse {
    let query = req.queryParams["q"] ?? ""
    let searchType = req.queryParams["type"] ?? "name"
    if query.isEmpty { return jsonError("q query parameter is required", status: 400) }

    do {
        let predicate: NSPredicate
        switch searchType {
        case "email": predicate = CNContact.predicateForContacts(matchingEmailAddress: query)
        case "phone": predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
        default: predicate = CNContact.predicateForContacts(matchingName: query)
        }
        let contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: allContactKeys())
        return jsonResponse(ContactsListResponse(count: contacts.count, contacts: contacts.map { contactToJSON($0) }))
    } catch {
        return jsonError("Search failed: \(error.localizedDescription)")
    }
}

func handleGetAllContacts() -> HTTPResponse {
    do {
        var contacts: [ContactJSON] = []
        let request = CNContactFetchRequest(keysToFetch: allContactKeys())
        request.sortOrder = .userDefault
        try contactStore.enumerateContacts(with: request) { contact, _ in
            contacts.append(contactToJSON(contact))
        }
        return jsonResponse(ContactsListResponse(count: contacts.count, contacts: contacts))
    } catch {
        return jsonError("Failed to enumerate contacts: \(error.localizedDescription)")
    }
}

func handleGetContact(id: String) -> HTTPResponse {
    do {
        let contact = try contactStore.unifiedContact(withIdentifier: id, keysToFetch: allContactKeys())
        return jsonResponse(SingleContactResponse(contact: contactToJSON(contact)))
    } catch {
        return jsonError("Contact not found: \(id)", status: 404)
    }
}

func handleCreateContact(req: HTTPRequest) -> HTTPResponse {
    guard let dict = req.jsonBody() else {
        return jsonError("Invalid JSON body", status: 400)
    }
    let contact = CNMutableContact()
    applyContactFields(contact, from: dict)
    do {
        let saveRequest = CNSaveRequest()
        saveRequest.add(contact, toContainerWithIdentifier: nil)
        try contactStore.execute(saveRequest)
        return jsonResponse(ContactCreateResponse(success: true, identifier: contact.identifier, message: "Contact created"), status: 201)
    } catch {
        return jsonError("Failed to create contact: \(error.localizedDescription)")
    }
}

func handleUpdateContact(id: String, req: HTTPRequest) -> HTTPResponse {
    guard let dict = req.jsonBody() else { return jsonError("Invalid JSON body", status: 400) }
    do {
        let existing = try contactStore.unifiedContact(withIdentifier: id, keysToFetch: allContactKeys())
        guard let contact = existing.mutableCopy() as? CNMutableContact else {
            return jsonError("Cannot create mutable copy of contact")
        }
        applyContactFields(contact, from: dict)
        let saveRequest = CNSaveRequest()
        saveRequest.update(contact)
        try contactStore.execute(saveRequest)
        return jsonSuccess("Contact updated")
    } catch {
        return jsonError("Failed to update contact: \(error.localizedDescription)")
    }
}

func handleDeleteContact(id: String) -> HTTPResponse {
    do {
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
        let contact = try contactStore.unifiedContact(withIdentifier: id, keysToFetch: keys)
        guard let mutable = contact.mutableCopy() as? CNMutableContact else {
            return jsonError("Cannot create mutable copy of contact")
        }
        let saveRequest = CNSaveRequest()
        saveRequest.delete(mutable)
        try contactStore.execute(saveRequest)
        return jsonSuccess("Contact deleted")
    } catch {
        return jsonError("Failed to delete contact: \(error.localizedDescription)")
    }
}

// MARK: - Field Application

private func applyContactFields(_ contact: CNMutableContact, from dict: [String: Any]) {
    if let v = dict["givenName"] as? String { contact.givenName = v }
    if let v = dict["familyName"] as? String { contact.familyName = v }
    if let v = dict["nickname"] as? String { contact.nickname = v }
    if let v = dict["organizationName"] as? String { contact.organizationName = v }
    if let v = dict["jobTitle"] as? String { contact.jobTitle = v }
    if let v = dict["note"] as? String { contact.note = v }

    if let phones = dict["phoneNumbers"] as? [[String: String]] {
        contact.phoneNumbers = phones.map { phone in
            let label = mapLabel(phone["label"] ?? "mobile", isPhone: true)
            return CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: phone["value"] ?? ""))
        }
    }
    if let emails = dict["emailAddresses"] as? [[String: String]] {
        contact.emailAddresses = emails.map { email in
            CNLabeledValue(label: mapLabel(email["label"] ?? "home"), value: (email["value"] ?? "") as NSString)
        }
    }
    if let bday = dict["birthday"] as? [String: Int] {
        var components = DateComponents()
        if let year = bday["year"] { components.year = year }
        if let month = bday["month"] { components.month = month }
        if let day = bday["day"] { components.day = day }
        contact.birthday = components
    }
}

private func mapLabel(_ label: String, isPhone: Bool = false) -> String {
    switch label.lowercased() {
    case "home": return CNLabelHome
    case "work": return CNLabelWork
    case "mobile", "cell": return isPhone ? CNLabelPhoneNumberMobile : CNLabelOther
    case "main": return isPhone ? CNLabelPhoneNumberMain : CNLabelOther
    default: return CNLabelOther
    }
}
