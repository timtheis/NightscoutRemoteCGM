//
//  SettingsView.swift
//  NightscoutRemoteCGM
//
//  Created by Ivan Valkou on 18.10.2019.
//  Copyright © 2019 Ivan Valkou. All rights reserved.
//

import SwiftUI
import Combine
import LoopKit

private let frameworkBundle = Bundle(for: SettingsViewModel.self)

final class SettingsViewModel: ObservableObject {
    let nightscoutService: NightscoutAPIService
    
    @Published var serviceStatus: SettingsViewServiceStatus = .unknown
    
    // Libre States via UserDefaults
    @Published var useDirectLibre: Bool {
        didSet { UserDefaults.standard.set(useDirectLibre ? "true" : "false", forKey: "com.loopkit.NightscoutRemoteCGM.UseDirectLibre") }
    }
    @Published var libreEmail: String {
        didSet { UserDefaults.standard.set(libreEmail, forKey: "com.loopkit.NightscoutRemoteCGM.LibreEmail") }
    }
    @Published var librePassword: String {
        didSet { UserDefaults.standard.set(librePassword, forKey: "com.loopkit.NightscoutRemoteCGM.LibrePassword") }
    }
    
    var url: String {
        return nightscoutService.url?.absoluteString ?? ""
    }
    
    let onDelete = PassthroughSubject<Void, Never>()
    let onClose = PassthroughSubject<Void, Never>()

    init(nightscoutService: NightscoutAPIService) {
        self.nightscoutService = nightscoutService
        
        // Initialize from UserDefaults
        self.useDirectLibre = UserDefaults.standard.string(forKey: "com.loopkit.NightscoutRemoteCGM.UseDirectLibre") == "true"
        self.libreEmail = UserDefaults.standard.string(forKey: "com.loopkit.NightscoutRemoteCGM.LibreEmail") ?? ""
        self.librePassword = UserDefaults.standard.string(forKey: "com.loopkit.NightscoutRemoteCGM.LibrePassword") ?? ""
    }
    
    func viewDidAppear(){
        if !useDirectLibre {
            updateServiceStatus()
        }
    }
    
    private func updateServiceStatus(){
        nightscoutService.checkServiceStatus { result in
            DispatchQueue.main.async {
                switch result {
                case .success():
                    self.serviceStatus = .ok
                case .failure(let err):
                    self.serviceStatus = .error(err)
                }
            }
        }
    }
    
    enum SettingsViewServiceStatus {
        case unknown
        case ok
        case error(Error)
        
        func localizedString() -> String {
            switch self {
            case .unknown: return ""
            case .ok: return "OK"
            case .error(let err): return err.localizedDescription
            }
        }
    }
}

public struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showingDeletionSheet = false
    
    public var body: some View {
        VStack {
            Text(LocalizedString("Nightscout Remote CGM", comment: "Title for the CGMManager option"))
                .font(.title)
                .fontWeight(.semibold)
                .padding(.top)

            Image("nightscout", bundle: frameworkBundle)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
            
            Form {
                Section(header: Text("Data Source")) {
                    Toggle("Direct Libre LinkUp", isOn: $viewModel.useDirectLibre)
                }

                if viewModel.useDirectLibre {
                    Section(header: Text("LibreLinkUp Credentials")) {
                        TextField("Email", text: $viewModel.libreEmail)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        
                        SecureField("Password", text: $viewModel.librePassword)
                    }
                    Section(footer: Text("Pulling 1-minute data directly from Abbott. Nightscout settings are bypassed.")) {
                        EmptyView()
                    }
                } else {
                    Section(header: Text("Nightscout Connection")) {
                        HStack {
                            Text("URL")
                            Spacer()
                            Text(viewModel.url).foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Status")
                            Spacer()
                            Text(viewModel.serviceStatus.localizedString()).foregroundColor(.secondary)
                        }
                    }
                }
                
                Section {
                    HStack {
                        Spacer()
                        deleteCGMButton
                        Spacer()
                    }
                }
            }
        }
        .navigationBarTitle(Text("CGM Settings", bundle: frameworkBundle))
        .navigationBarItems(
            trailing: Button(action: {
                self.viewModel.onClose.send()
            }, label: {
                Text("Done", bundle: frameworkBundle).fontWeight(.bold)
            })
        ).onAppear {
            viewModel.viewDidAppear()
        }
    }
    
    private var deleteCGMButton: some View {
        Button(action: {
            showingDeletionSheet = true
        }, label: {
            Text("Delete CGM", bundle: frameworkBundle).foregroundColor(.red)
        }).actionSheet(isPresented: $showingDeletionSheet) {
            ActionSheet(
                title: Text("Are you sure you want to delete this CGM?"),
                buttons: [
                    .destructive(Text("Delete CGM")) {
                        self.viewModel.onDelete.send()
                    },
                    .cancel(),
                ]
            )
        }
    }
}